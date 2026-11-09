import Foundation

final class ContentPreviewLoad {
    enum Outcome { case ready(ContentPreview), sourceChanged, failed(String) }
    private var runner: SearchRunner?
    private var materialization: MaterializationRequest?
    private var timeout: DispatchWorkItem?
    private var completion: ((Outcome) -> Void)?
    private var closed = false
    var isLoading: Bool { !closed && completion != nil }

    func cancel() {
        closed = true; completion = nil
        timeout?.cancel(); timeout = nil
        runner?.cancel(); runner = nil
        materialization?.cancel(); materialization?.release(); materialization = nil
    }
    private func finish(_ outcome: Outcome) {
        guard !closed else { return }
        let callback = completion
        cancel(); callback?(outcome)
    }
    func start(hit: Hit, queryIndex: Int, occurrence: Int, context: Bool, localOnly: Bool,
               cli: String, completion: @escaping (Outcome) -> Void) {
        guard !closed else { return }
        self.completion = completion
        guard let original = hit.contentPreview, let expected = original.sourceGeneration,
              original.snippets.indices.contains(queryIndex), original.snippets[queryIndex].query != nil else {
            finish(.failed("Kein fortsetzbarer Inhaltsbeleg.")); return
        }
        let limit = DispatchWorkItem { [weak self] in self?.finish(.failed("Nachladen nach fünf Sekunden beendet. Bisheriger Beleg bleibt erhalten.")) }
        timeout = limit; searchDeliveryQueue.asyncAfter(deadline: .now() + 5, execute: limit)
        func read(_ path: String, bytes: Data) {
            guard !closed else { return }
            guard ContentSourceGeneration.current(hit.filesystemPathData, localOnly: localOnly) == expected,
                  let leaf = ContentSourceGeneration.current(bytes, localOnly: localOnly),
                  let row = preservedJSONObject(jsonlData(for: [hit])) else { finish(.sourceChanged); return }
            var request: [String: Any] = ["schemaVersion": hit.filesystemPathBytes == nil ? 1 : 2, "hit": row,
                "filePath": path, "fileGeneration": leaf.json, "queryIndex": queryIndex,
                "occurrence": occurrence, "context": context]
            if hit.filesystemPathBytes != nil { request["filePathBytes"] = bytes.base64EncodedString() }
            guard let data = try? JSONSerialization.data(withJSONObject: request), data.count <= 128 * 1024,
                  let json = String(data: data, encoding: .utf8) else { finish(.failed("Nachladeauftrag überschreitet seine Größe.")); return }
            let operation = SearchRunner(); runner = operation
            var response: ContentPreview?
            operation.start(arguments: ["-B", cli, "--preview-request", json] + (localOnly ? ["--local-only"] : []), onBatch: { [weak self] rows, _ in
                guard let self, !self.closed, rows.count == 1, rows[0].identity == hit.identity else { return }
                response = rows[0].contentPreview
            }, completion: { [weak self] exit in
                guard let self, !self.closed else { return }
                guard ContentSourceGeneration.current(hit.filesystemPathData, localOnly: localOnly) == expected,
                      response?.status != "sourceChanged" else { self.finish(.sourceChanged); return }
                guard exit.status == 0, exit.reason == .exit, let response, response.navigation != nil else {
                    self.finish(.failed(exit.errorMessage ?? "Fundstelle konnte nicht geladen werden.")); return
                }
                self.finish(.ready(response))
            })
        }
        if !hit.isMember { read(hit.filesystemPath, bytes: hit.filesystemPathData); return }
        materialization = MaterializationManager.shared.request(hit, localOnly: localOnly) { [weak self] outcome in
            guard let self, !self.closed else { return }
            switch outcome {
            case .ready(let url): read(url.path, bytes: Data(url.path.utf8))
            case .failed(let reason): self.finish(.failed(reason))
            case .cancelled: self.finish(.failed("Nachladen abgebrochen."))
            }
        }
    }
    deinit { timeout?.cancel(); runner?.cancel(); materialization?.cancel(); materialization?.release() }
}
