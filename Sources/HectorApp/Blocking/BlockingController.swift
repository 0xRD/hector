import AppKit
import Foundation
import HectorCore
import Observation
import Security

/// The user's blocklist (a draft saved on disk) and the helper that enforces it.
///
/// Edits only change the draft. "Apply" sends the draft to the helper, which recompiles and
/// enforces it; the helper's status then reports what is really applied.
@MainActor
@Observable
final class BlockingController {
    enum HelperState: Equatable {
        case checking
        case notInstalled
        case ready(HelperStatus)
        case unreachable(String)
    }

    private(set) var helper: HelperState = .checking
    private(set) var isWorking = false
    private(set) var lastError: String?

    var draft: Blocklist {
        didSet { saveDraft() }
    }

    private static var draftURL: URL {
        LegacyMigration.userDataDirectory.appending(path: "blocklist.json")
    }

    init() {
        draft = (try? Blocklist.load(from: Self.draftURL)) ?? Blocklist()
    }

    // MARK: - State

    var helperStatus: HelperStatus? {
        if case .ready(let status) = helper { return status }
        return nil
    }

    var isHelperReady: Bool { helperStatus != nil }

    /// What pf enforces right now.
    var applied: Blocklist { helperStatus?.blocklist ?? Blocklist() }

    /// Rules added, removed or toggled, plus countries switched, compared with what is applied.
    var pendingChanges: Int {
        let before = Dictionary(uniqueKeysWithValues: applied.rules.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: draft.rules.map { ($0.id, $0) })
        let ruleChanges = Set(before.keys).union(after.keys).filter { before[$0]?.isEnabled != after[$0]?.isEnabled }.count
        return ruleChanges + applied.blockedCountries.symmetricDifference(draft.blockedCountries).count
    }

    func isPending(_ rule: Rule) -> Bool {
        applied.rules.first { $0.id == rule.id }?.isEnabled != rule.isEnabled
    }

    // MARK: - Helper

    func refresh() async {
        guard HelperClient.isInstalled else {
            helper = .notInstalled
            return
        }
        do {
            let response = try await Task.detached { try HelperClient.send(.status, timeout: 10) }.value
            handle(response)
            // First run with the helper already set up elsewhere (CLI): start from what it enforces.
            if !FileManager.default.fileExists(atPath: Self.draftURL.path), let applied = helperStatus?.blocklist {
                draft = applied
            }
        } catch {
            helper = .unreachable(String(describing: error))
        }
    }

    func apply() async {
        let draft = draft
        await perform { .apply(draft, authorization: try HelperAuthorization.externalForm()) }
    }

    func discard() {
        draft = applied
    }

    func flush() async {
        await perform { .flush(authorization: try HelperAuthorization.externalForm()) }
        if lastError == nil { draft = Blocklist() }
    }

    /// Builds the request off the main thread (getting the authorization may show the system
    /// password dialog), then sends it.
    private func perform(_ makeRequest: @escaping @Sendable () throws -> HelperRequest) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let response = try await Task.detached { try HelperClient.send(makeRequest()) }.value
            handle(response)
        } catch let error as HelperAuthorization.AuthorizationError where error.status == errAuthorizationCanceled {
            return
        } catch {
            lastError = String(describing: error)
        }
    }

    private func handle(_ response: HelperResponse) {
        switch response {
        case .status(let status): helper = .ready(status)
        case .failure(let message): lastError = message
        case .snapshot, .processes, .toolOutput: break
        }
    }

    // MARK: - Install

    /// Runs `hectord install` as root. macOS shows its own administrator password prompt.
    func installHelper() async {
        guard let binary = Self.bundledHelper else {
            lastError = "hectord was not found next to the app."
            return
        }
        await runAsAdministrator("\(AdministratorScript.shellQuoted(binary.path)) install")
        for _ in 0..<20 where !HelperClient.isInstalled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refresh()
    }

    func uninstallHelper() async {
        await runAsAdministrator("\(AdministratorScript.shellQuoted(HelperPaths.installedBinary)) uninstall")
        await refresh()
    }

    private func runAsAdministrator(_ command: String) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        if case .failure(let message) = AdministratorScript.run(command) {
            lastError = message
        }
    }

    /// `Hector.app/Contents/Helpers/hectord`, or next to the executable when run with `swift run`.
    private static var bundledHelper: URL? {
        let candidates = [
            Bundle.main.bundleURL.appending(path: "Contents/Helpers/hectord"),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "hectord"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Editing the draft

    func isCountryBlocked(_ code: String) -> Bool {
        draft.blockedCountries.contains(code)
    }

    func setCountry(_ code: String, blocked: Bool) {
        draft.setCountry(code, blocked: blocked)
    }

    func addressRule(_ address: IPAddress) -> Rule? {
        draft.addressRule(for: address)
    }

    func toggleAddress(_ address: IPAddress, note: String) {
        if let rule = draft.addressRule(for: address) {
            draft.rules.removeAll { $0.id == rule.id }
        } else {
            draft.rules.append(Rule(target: .network(CIDR(address)), note: note, source: .connections))
        }
    }

    /// Adds a rule typed by the user; returns `false` when the text is neither a domain nor a network.
    @discardableResult
    func addRule(_ text: String, note: String) -> Bool {
        guard let target = RuleTarget(text) else { return false }
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        draft.rules.insert(Rule(target: target, note: trimmedNote.isEmpty ? nil : trimmedNote), at: 0)
        return true
    }

    func setRule(_ id: Rule.ID, enabled: Bool) {
        guard let index = draft.rules.firstIndex(where: { $0.id == id }) else { return }
        draft.rules[index].isEnabled = enabled
    }

    func removeRule(_ id: Rule.ID) {
        draft.rules.removeAll { $0.id == id }
    }

    private func saveDraft() {
        try? FileManager.default.createDirectory(at: Self.draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? draft.save(to: Self.draftURL)
    }
}
