import AppKit

@main struct ConfigurationProbe {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var original = SearchConfiguration()
        original.mode = .metadata
        original.regex = true
        original.caseSensitive = true
        original.archives = true
        original.includeHidden = true
        original.exact = true
        original.only = "files"
        original.metadataField = "Title"
        original.pixelTexts = ["1.000 px", "2000", "", ""]
        original.rawFacts = ["min-size": "1 B", "max-size": "1 KiB",
                             "modified-from": "2000-01-01T00:00:00Z",
                             "modified-to": "2099-01-01T00:00:00+02:00",
                             "created-from": "2000-01-01T00:00:00Z",
                             "created-to": "2099-01-01T00:00:00Z"]
        original.exclusions = ["node_modules", "Cache/*.zip", " whitespace ", "100%+#Ü.txt", "-cache", "--hidden"]
        var url = URLComponents()
        url.scheme = "favenio"
        url.host = "results"
        url.queryItems = original.queryItems
        let decoded = SearchConfiguration.fromQueryItems(
            URLComponents(url: url.url!, resolvingAgainstBaseURL: false)!.queryItems!)
        precondition(original == decoded, "Options-URL verliert Werte")
        let args = decoded.arguments(pattern: "Winter", root: "/fixture")!
        precondition(args.filter { $0.hasPrefix("--exclude=") }
            .map { String($0.dropFirst("--exclude=".count)) } == original.exclusions)
        precondition(args.contains("1000") && args.contains("--metadata"))
        let legacy = SearchConfiguration.fromQueryItems([URLQueryItem(name: "content", value: "1")])
        precondition(legacy.mode == .content && !legacy.archives && !legacy.regex && !legacy.caseSensitive)
        for texts in [["10.5", "", "", ""], ["2000", "1000", "", ""],
                      ["-1", "", "", ""], [String(Int.max) + "0", "", "", ""]] {
            var invalid = original
            invalid.pixelTexts = texts
            let restored = SearchConfiguration.fromQueryItems(invalid.queryItems)
            precondition(restored.pixelTexts == texts)
            precondition(restored.arguments(pattern: "x", root: "/fixture") == nil)
            let fields = texts.map { NSTextField(string: $0) }
            precondition(validatePixelFields(fields).error != nil)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("-cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "x".write(to: fixture.appendingPathComponent("-cache/needle.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: fixture.appendingPathComponent("needle.txt"), atomically: true, encoding: .utf8)
        var dashPattern = SearchConfiguration()
        dashPattern.exclusions = ["-cache", "--hidden"]
        var found: [Hit] = []
        let outcome = runSearchStreaming(arguments: dashPattern.arguments(pattern: "needle", root: fixture.path)!,
                                         onHit: { found.append($0) }, onProgress: { _ in })
        precondition(outcome.status == 0 && found.count == 1 && found[0].filesystemPath == fixture.appendingPathComponent("needle.txt").path)
        var factsOnly = SearchConfiguration()
        factsOnly.mode = .metadata
        factsOnly.rawFacts = original.rawFacts
        factsOnly.exclusions = ["-cache"]
        precondition(factsOnly.hasPositiveFilter)
        precondition(FactFilterOption.all.allSatisfy { factsOnly.filterSummary.contains($0.title) })
        let factsArguments = factsOnly.arguments(pattern: "", root: fixture.path)!
        precondition(!factsArguments.contains("--metadata") && !factsArguments.contains("--content"))
        found = []
        let factsExit = runSearchStreaming(arguments: factsArguments,
                                           onHit: { found.append($0) }, onProgress: { _ in })
        precondition(factsExit.status == 0 && found.count == 1)
        var excludedOnly = SearchConfiguration()
        excludedOnly.exclusions = ["x"]
        precondition(!excludedOnly.hasPositiveFilter && excludedOnly.arguments(pattern: "", root: fixture.path) == nil)
        for invalid in [["min-size": "-1"], ["min-size": "10", "max-size": "1"],
                        ["modified-from": "2026-09-05"], ["created-to": "2026-09-05T12:00:00"]] {
            factsOnly.rawFacts = invalid
            let restored = SearchConfiguration.fromQueryItems(factsOnly.queryItems)
            precondition(restored.rawFacts == invalid && restored.hasPositiveFilter)
            let result = runSearchStreaming(arguments: restored.arguments(pattern: "", root: fixture.path)!, onProgress: { _ in })
            precondition(result.status == 2 && !(result.errorMessage ?? "").isEmpty)
        }
        let view = SearchFilterView()
        view.rawFacts = original.rawFacts
        precondition(view.rawFacts == original.rawFacts)
        view.exclusions = original.exclusions
        precondition(view.exclusions == original.exclusions)
        view.exclusionsEditor.string = "a\n\n space \nb"
        precondition(view.exclusions == ["a", " space ", "b"])
        var changes = 0
        view.onChange = { changes += 1 }
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        precondition(changes == 1)
        if CommandLine.arguments.count > 1 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView!.wantsLayer = true
            window.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.contentView!.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
                view.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12)])
            view.exclusions = ["node_modules", "Cache/*.zip"]
            view.rawFacts = ["min-size": "1 MiB", "max-size": "10 MiB",
                             "modified-from": "2026-09-05T00:00:00Z",
                             "modified-to": "2026-09-05T23:59:59+02:00"]
            window.contentView!.layoutSubtreeIfNeeded()
            precondition(!window.isVisible && !window.isKeyWindow)
            guard let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds)
            else { fatalError("Offscreen-Bitmap fehlt") }
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("CONFIGURATION OK")
    }
}
