import AppKit

extension LocalSearchController: FastraHandoffOwner {
    var handoffRunID: String? { run?.id }
    var handoffHits: [Hit] { host?.hits ?? [] }
    func handoffIssue(_ text: String) { host?.presentActionIssue(summary: text, detail: nil) }
}
