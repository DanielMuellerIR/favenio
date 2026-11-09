import Foundation

private final class FilterDeadline {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.lock(); expired = true; lock.unlock() }
    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

final class ResultFilterRun {
    let runner = SearchRunner()
    private let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("favenio-result-filter-\(ProcessInfo.processInfo.processIdentifier)-" + UUID().uuidString)
    private let workspaceLock = NSLock()
    private var closing = false

    func cancel() { runner.cancel() }

    private func createWorkspace() throws {
        workspaceLock.lock(); defer { workspaceLock.unlock() }
        if closing || runner.isCancelled { throw CocoaError(.userCancelled) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func cleanupWorkspace() {
        workspaceLock.lock(); defer { workspaceLock.unlock() }
        closing = true
        try? FileManager.default.removeItem(at: workspace)
    }

    func stopForTermination(deadline: TimeInterval) {
        runner.stopForTermination(deadline: deadline)
        cleanupWorkspace()
    }

    func start(_ hits: [Hit], query: String, root: String?, dateReferenceTime: String? = nil, frozenDateResolution: Data? = nil,
               onDateResolution: @escaping (Data) -> Void = { _ in },
               completion: @escaping (Set<HitIdentity>?, String?) -> Void) {
        let runner = self.runner
        let deadline = FilterDeadline()
        let timeout = DispatchWorkItem { deadline.expire(); runner.cancel() }
        searchDeliveryQueue.asyncAfter(deadline: .now() + 25, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func finish(_ accepted: Set<HitIdentity>?, _ error: String?) {
                DispatchQueue.global().async {
                    self.cleanupWorkspace()
                    searchDeliveryQueue.async {
                        timeout.cancel()
                        completion(accepted, deadline.isExpired ? "Ansichtsfilter überschreitet sein Zeitbudget." : error)
                    }
                }
            }
            do {
                guard let cli = findCLI() else { throw NSError(domain: "Favenio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Der Suchkern wurde nicht gefunden."]) }
                try createWorkspace()
                let file = workspace.appendingPathComponent("results.jsonl")
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                       attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: file)
                do {
                    for hit in hits {
                        if runner.isCancelled { throw CocoaError(.userCancelled) }
                        let known = Hit(path: hit.path, kind: hit.kind, line: nil, size: hit.size,
                            filesystemPath: hit.filesystemPath, archiveMembers: hit.archiveMembers,
                            archiveMemberBytes: hit.archiveMemberBytes, isDirectory: hit.isDirectory,
                            width: hit.width, height: hit.height, modified: hit.modified, created: hit.created,
                            contentEncoding: hit.contentEncoding, searchRootBytes: hit.searchRootBytes,
                            finderMetadata: hit.finderMetadata, filesystemPathBytes: hit.filesystemPathBytes)
                        let data = jsonlData(for: [known])
                        guard data.count <= SearchRunner.recordByteLimit else { throw NSError(domain: "Favenio", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Ein Treffer überschreitet die Filter-Recordgrenze."]) }
                        try handle.write(contentsOf: data)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if runner.isCancelled { throw CocoaError(.userCancelled) }
                var accepted: Set<HitIdentity> = []
                var proofError: String?
                let arguments = ["-u", cli, "--filter-results=" + file.path, "--criteria-json=" + query]
                    + (root.map { ["--results-root=" + $0] } ?? []) + DateRangeTransport.referenceArguments(dateReferenceTime) + DateRangeTransport.frozenArguments(frozenDateResolution)
                runner.start(arguments: arguments,
                    onBatch: { matches, _ in accepted.formUnion(matches.map { $0.identity }) },
                    onDateResolution: { data in
                        var configuration = SearchConfiguration(); configuration.criteriaJSON = query; configuration.dateReferenceTime = dateReferenceTime
                        if DateRangeTransport.bound(data, to: configuration) { onDateResolution(data) }
                        else { proofError = "Datumsbeleg passt nicht zum Ansichtsfilter."; runner.cancel() }
                    },
                    completion: { exit in
                        if proofError == nil && exit.reason == .exit && [0, 1].contains(exit.status) {
                            finish(accepted, nil)
                        } else {
                            finish(nil, proofError ?? exit.errorMessage ?? "Ansichtsfilter abgebrochen oder fehlgeschlagen.")
                        }
                    })
            } catch { finish(nil, error.localizedDescription) }
        }
    }
}
