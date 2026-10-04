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
        #if DEBUG
        if DemoData.isEnabled {
            draft = DemoData.draftBlocklist
            helper = .ready(DemoData.helperStatus)
            return
        }
        #endif
        draft = (try? Blocklist.load(from: Self.draftURL)) ?? Blocklist()
    }

    /// `HECTOR_DEMO=1` (debug builds): a sample blocklist, never saved; the helper is never contacted.
    private static var isDemo: Bool {
        #if DEBUG
        DemoData.isEnabled
        #else
        false
        #endif
    }

    // MARK: - State

    var helperStatus: HelperStatus? {
        if case .ready(let status) = helper { return status }
        return nil
    }

    var isHelperReady: Bool { helperStatus != nil }

    /// What pf enforces right now.
    var applied: Blocklist { helperStatus?.blocklist ?? Blocklist() }

    /// What is enforced, in a few words: "2 lists · 3 rules", or `nil` when nothing is. Hosts lists
    /// count as much as rules: they are usually most of what is blocked.
    var enforcedSummary: String? {
        let applied = applied
        var parts: [String] = []
        let lists = applied.hostsLists.count
        if lists > 0 { parts.append("\(lists) list\(lists == 1 ? "" : "s")") }
        let rules = applied.rules.filter(\.isEnabled).count
        if rules > 0 { parts.append("\(rules) rule\(rules == 1 ? "" : "s")") }
        let countries = applied.blockedCountries.count
        if countries > 0 { parts.append("\(countries) countr\(countries == 1 ? "y" : "ies")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Domains and networks blocked, for a second line: "113,627 domains".
    var enforcedVolume: String? {
        guard let status = helperStatus else { return nil }
        let domains = status.hostsDomainCount + (status.listDomainCount ?? 0)
        let networks = status.blockTableCount + status.geoTableCount
        var parts: [String] = []
        if domains > 0 { parts.append("\(Display.count(domains)) domain\(domains == 1 ? "" : "s")") }
        if networks > 0 { parts.append("\(Display.count(networks)) network\(networks == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Rules added, removed or toggled, plus countries and hosts lists switched, compared with what
    /// is applied.
    var pendingChanges: Int {
        let before = Dictionary(uniqueKeysWithValues: applied.rules.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: draft.rules.map { ($0.id, $0) })
        let ruleChanges = Set(before.keys).union(after.keys).filter { before[$0]?.isEnabled != after[$0]?.isEnabled }.count
        let countryChanges = applied.blockedCountries.symmetricDifference(draft.blockedCountries).count
        let listChanges = applied.hostsLists.symmetricDifference(draft.hostsLists).count
        return ruleChanges + countryChanges + listChanges
    }

    func isPending(_ rule: Rule) -> Bool {
        applied.rules.first { $0.id == rule.id }?.isEnabled != rule.isEnabled
    }

    // MARK: - Helper

    func refresh() async {
        guard !Self.isDemo else { return }
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

    /// Asks the helper to download the subscribed lists now. Needs the same approval as Apply.
    func refreshHostsLists() async {
        await perform { .refreshHostsLists(authorization: try HelperAuthorization.externalForm()) }
    }

    func flush() async {
        await perform { .flush(authorization: try HelperAuthorization.externalForm()) }
        if lastError == nil { draft = Blocklist() }
    }

    /// Builds the request off the main thread (getting the authorization may show the system
    /// password dialog), then sends it.
    private func perform(_ makeRequest: @escaping @Sendable () throws -> HelperRequest) async {
        guard !Self.isDemo else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let response = try await Task.detached { try HelperClient.sendChecked(makeRequest()) }.value
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
        case .snapshot, .processes, .toolOutput, .hello: break
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
        // The old helper's socket file may still be there while launchd starts the new one, which
        // refuses connections for a moment: wait until a helper of this version answers.
        for _ in 0..<40 {
            let info = await Task.detached { try? HelperClient.info(timeout: 1) }.value
            if info?.version == HectorVersion.current { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refresh()
    }

    func uninstallHelper() async {
        await runAsAdministrator("\(AdministratorScript.shellQuoted(HelperPaths.installedBinary)) uninstall")
        await refresh()
    }

    private func runAsAdministrator(_ command: String) async {
        guard !Self.isDemo else { return }
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

    // MARK: Hosts lists

    func isListEnabled(_ id: String) -> Bool {
        draft.hostsLists.contains(id)
    }

    func setList(_ id: String, enabled: Bool) {
        draft.setHostsList(id, enabled: enabled)
    }

    /// What the helper reports about a list, `nil` before its first download.
    func listState(_ id: String) -> HostsListState? {
        helperStatus?.hostsLists?.first { $0.id == id }
    }

    /// `false` when the installed helper predates hosts lists and would ignore them.
    var helperSupportsLists: Bool {
        helperStatus?.hostsLists != nil
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
        guard !Self.isDemo else { return }
        try? FileManager.default.createDirectory(at: Self.draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? draft.save(to: Self.draftURL)
    }
}
