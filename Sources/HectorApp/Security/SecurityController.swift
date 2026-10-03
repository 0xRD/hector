import Foundation
import HectorCore
import Observation

/// The persistence scan, the process list, and what is known about the code behind them: code
/// signatures (computed locally) and VirusTotal results (looked up only when the user asks).
@MainActor
@Observable
final class SecurityController {
    enum SignatureState: Equatable, Sendable {
        case analyzing
        case analyzed(CodeSignatureInfo)
        case failed(String)
    }

    enum VirusTotalState: Equatable, Sendable {
        /// Hashing the file, or waiting for a free slot (4 lookups per minute), or on the network.
        case checking
        case done(VirusTotalLookup)
        case failed(String)
    }

    // MARK: Persistence

    private(set) var persistence: PersistenceReport?
    private(set) var isScanningPersistence = false
    /// Why login items are missing, when the helper could not list them.
    private(set) var persistenceHelperIssue: String?
    var includeAppleItems = false

    // MARK: Processes

    private(set) var processes: ProcessSnapshot?
    private(set) var processFlags: [Int32: Set<ProcessFlag>] = [:]
    private(set) var processesThroughHelper = false
    private(set) var isLoadingProcesses = false

    // MARK: Code

    /// Keyed by the path that was analyzed: an executable or a bundle.
    private(set) var signatures: [String: SignatureState] = [:]
    /// Keyed by the same path as `signatures`.
    private(set) var virusTotal: [String: VirusTotalState] = [:]
    /// Read lazily from views, so not observed: filling it must not trigger a view update.
    @ObservationIgnored private var quarantine: [String: QuarantineInfo?] = [:]
    @ObservationIgnored private var virusTotalTask: Task<Void, Never>?
    private(set) var isCheckingAll = false
    /// The free tier's quota is used up (refused locally or by VirusTotal): "Check all" stops.
    private(set) var quotaExhausted = false

    // MARK: API key

    private(set) var hasAPIKey = false
    private(set) var keyMessage: String?
    private let keyStore = APIKeyStore()
    private let rateLimiter = VirusTotalClient.defaultRateLimiter()

    init() {
        refreshKeyState()
    }

    // MARK: - Persistence

    func scanPersistence() async {
        guard !isScanningPersistence else { return }
        isScanningPersistence = true
        defer { isScanningPersistence = false }
        let includeApple = includeAppleItems
        let (report, issue) = await Task.detached(priority: .userInitiated) {
            let (output, issue) = Self.backgroundTasksFromHelper()
            let options = PersistenceScanner.Options(includeApple: includeApple, backgroundTaskOutput: output)
            return (PersistenceScanner().scan(options: options), issue)
        }.value
        persistence = report
        persistenceHelperIssue = issue
        await analyzeSignatures(of: report.items.compactMap(Self.codePath(of:)))
    }

    /// Login items need root: the helper runs `sfltool dumpbtm` for the app.
    nonisolated private static func backgroundTasksFromHelper() -> (ToolOutput?, String?) {
        guard HelperClient.isInstalled else { return (nil, nil) }
        do {
            switch try HelperClient.send(.backgroundTasks, timeout: 30) {
            case .toolOutput(let text, let truncated):
                return (ToolOutput(output: text, truncated: truncated), nil)
            case .failure(let message):
                return (nil, message)
            default:
                return (nil, "Unexpected reply from the helper.")
            }
        } catch {
            return (nil, String(describing: error))
        }
    }

    /// The code a persistence item runs, as a path to analyze.
    nonisolated static func codePath(of item: PersistenceItem) -> String? {
        guard let path = item.executablePath ?? item.owningBundlePath, path.hasPrefix("/") else { return nil }
        return path
    }

    // MARK: - Processes

    func refreshProcesses() async {
        guard !isLoadingProcesses else { return }
        isLoadingProcesses = true
        defer { isLoadingProcesses = false }
        let (snapshot, throughHelper, flags) = await Task.detached(priority: .userInitiated) {
            var snapshot: ProcessSnapshot?
            if HelperClient.isInstalled, case .processes(let fromHelper)? = try? HelperClient.send(.processes, timeout: 10) {
                snapshot = fromHelper
            }
            let result = snapshot ?? ProcessCollector().snapshot()
            let flags = Dictionary(uniqueKeysWithValues: result.processes.map {
                ($0.pid, ProcessFlag.flags(forExecutable: $0.executablePath))
            })
            return (result, snapshot != nil, flags)
        }.value
        processes = snapshot
        processesThroughHelper = throughHelper
        processFlags = flags
        await analyzeSignatures(of: snapshot.processes.compactMap(\.executablePath))
    }

    func quarantineInfo(for process: RunningProcess) -> QuarantineInfo? {
        let key = process.appBundlePath ?? process.executablePath ?? ""
        if let cached = quarantine[key] { return cached }
        let info = Quarantine.info(for: process)
        quarantine[key] = info
        return info
    }

    // MARK: - Signatures

    /// Analyzes the paths not analyzed yet, a batch at a time so the lists fill in progressively.
    func analyzeSignatures(of paths: [String]) async {
        var seen = Set<String>()
        let pending = paths.filter { signatures[$0] == nil && seen.insert($0).inserted }
        for path in pending { signatures[path] = .analyzing }
        let batchSize = 24
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            let results = await Task.detached(priority: .utility) {
                batch.map { path -> (String, SignatureState) in
                    do {
                        return (path, .analyzed(try CodeSignature.analyze(URL(fileURLWithPath: path))))
                    } catch {
                        return (path, .failed(String(describing: error)))
                    }
                }
            }.value
            for (path, state) in results { signatures[path] = state }
        }
    }

    func signature(of path: String?) -> CodeSignatureInfo? {
        guard let path, case .analyzed(let info)? = signatures[path] else { return nil }
        return info
    }

    // MARK: - VirusTotal

    /// Looks up one file. Only its SHA-256 leaves this Mac.
    func checkVirusTotal(path: String, refresh: Bool = false) async {
        guard virusTotal[path] != .checking else { return }
        guard let client = makeClient(reportingTo: path) else { return }
        await lookUp(path: path, client: client, refresh: refresh)
    }

    /// Looks up every path without a result yet, one after the other within the free-tier limits.
    func checkAllVirusTotal(paths: [String]) {
        guard !isCheckingAll, let client = makeClient(reportingTo: nil) else { return }
        var seen = Set<String>()
        let pending = paths.filter { path in
            guard seen.insert(path).inserted else { return false }
            if case .done? = virusTotal[path] { return false }
            return virusTotal[path] != .checking
        }
        guard !pending.isEmpty else { return }
        isCheckingAll = true
        virusTotalTask = Task {
            defer { isCheckingAll = false }
            for path in pending {
                if Task.isCancelled { break }
                await lookUp(path: path, client: client, refresh: false)
                // The daily quota is gone: the rest would fail the same way.
                if quotaExhausted { break }
            }
        }
    }

    func cancelVirusTotal() {
        virusTotalTask?.cancel()
        virusTotalTask = nil
        for (path, state) in virusTotal where state == .checking { virusTotal[path] = nil }
        isCheckingAll = false
    }

    private func makeClient(reportingTo path: String?) -> VirusTotalClient? {
        do {
            guard let key = try keyStore.read() else {
                if let path { virusTotal[path] = .failed("Add your VirusTotal API key in Settings first.") }
                keyMessage = "Add your VirusTotal API key to look files up."
                return nil
            }
            return try VirusTotalClient(apiKey: key, rateLimiter: rateLimiter)
        } catch {
            if let path { virusTotal[path] = .failed(String(describing: error)) }
            keyMessage = String(describing: error)
            return nil
        }
    }

    private func lookUp(path: String, client: VirusTotalClient, refresh: Bool) async {
        virusTotal[path] = .checking
        let target = FileHash.hashTarget(for: URL(fileURLWithPath: path), signature: signature(of: path))
        do {
            // Not detached, so cancelling "Check all" also stops a lookup waiting for a free slot.
            // The client is nonisolated: hashing and the request run off the main actor.
            let lookup = try await client.lookup(fileAt: target, refresh: refresh)
            virusTotal[path] = .done(lookup)
            quotaExhausted = false
        } catch is CancellationError {
            virusTotal[path] = nil
        } catch let error as VirusTotalError {
            switch error {
            case .dailyQuotaExhausted, .rateLimited: quotaExhausted = true
            default: break
            }
            virusTotal[path] = .failed(error.description)
        } catch {
            virusTotal[path] = .failed(String(describing: error))
        }
    }

    // MARK: - API key

    func refreshKeyState() {
        do {
            hasAPIKey = try keyStore.read() != nil
        } catch {
            hasAPIKey = false
            keyMessage = String(describing: error)
        }
    }

    /// Stores the key; returns `true` when it was saved.
    @discardableResult
    func saveKey(_ key: String) -> Bool {
        do {
            try keyStore.save(key)
            keyMessage = nil
            refreshKeyState()
            // Earlier "add your key" failures can now be retried.
            for (path, state) in virusTotal {
                if case .failed = state { virusTotal[path] = nil }
            }
            return true
        } catch {
            keyMessage = String(describing: error)
            return false
        }
    }

    func deleteKey() {
        do {
            try keyStore.delete()
            keyMessage = nil
        } catch {
            keyMessage = String(describing: error)
        }
        refreshKeyState()
    }
}
