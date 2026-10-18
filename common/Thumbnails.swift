import AppKit
import Darwin
import ImageIO

struct ThumbnailResult {
    let image: CGImage?
    let message: String
    var cost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
}

final class ThumbnailLoad {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var materialization: MaterializationRequest?
    var operation: Operation?
    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = stopped
        lock.unlock()
        if stop && process.isRunning { process.terminate() }
    }
    func attach(_ request: MaterializationRequest?) {
        lock.lock()
        materialization = request
        let stop = stopped
        lock.unlock()
        if stop { request?.cancel() }
    }
    func cancel() {
        lock.lock()
        stopped = true
        let child = process
        let request = materialization
        lock.unlock()
        operation?.cancel()
        if child?.isRunning == true { child?.terminate() }
        request?.cancel()
    }
}

final class ThumbnailLoader {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumPixels = 32_000_000
    static let maximumContainerBytes = 256 * 1024 * 1024
    static let maximumCacheBytes = 16 * 1024 * 1024
    static let maximumCacheCount = 64
    static let pixelEdge = 256
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp"]
    var interpreter = pythonPath
    var cliPath: String?
    var manager = MaterializationManager.shared
    private let lock = NSLock()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "favenio.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private struct Cached {
        let generation: ContentSourceGeneration
        let value: ThumbnailResult
    }
    private var cache: [HitIdentity: Cached] = [:]
    private var recency: [HitIdentity] = []
    private var jobs: [HitIdentity: ThumbnailLoad] = [:]
    private var bytes = 0, running = 0, peak = 0, decoded = 0
    var state: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "cacheCount": cache.count, "cacheBytes": bytes, "pending": jobs.count, "running": running,
            "peakRunning": peak, "decoded": decoded,
        ]
    }

    func cancel(_ identity: HitIdentity) {
        lock.lock()
        let job = jobs.removeValue(forKey: identity)
        lock.unlock()
        job?.cancel()
    }
    func cancelAll(clearCache: Bool = false) {
        lock.lock()
        let active = Array(jobs.values)
        jobs.removeAll()
        if clearCache {
            cache.removeAll()
            recency.removeAll()
            bytes = 0
        }
        lock.unlock()
        active.forEach { $0.cancel() }
    }
    func prune(to identities: Set<HitIdentity>) {
        lock.lock()
        for key in Array(cache.keys) where !identities.contains(key) {
            bytes -= cache.removeValue(forKey: key)!.value.cost
            recency.removeAll { $0 == key }
        }
        lock.unlock()
    }
    private func cached(_ hit: Hit, generation: ContentSourceGeneration) -> ThumbnailResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[hit.identity], entry.generation == generation else { return nil }
        recency.removeAll { $0 == hit.identity }
        recency.append(hit.identity)
        return entry.value
    }
    private func store(_ value: ThumbnailResult, hit: Hit, generation: ContentSourceGeneration) {
        lock.lock()
        defer { lock.unlock() }
        if let old = cache.removeValue(forKey: hit.identity) { bytes -= old.value.cost }
        recency.removeAll { $0 == hit.identity }
        recency.append(hit.identity)
        cache[hit.identity] = Cached(generation: generation, value: value)
        bytes += value.cost
        while cache.count > Self.maximumCacheCount || bytes > Self.maximumCacheBytes {
            let key = recency.removeFirst()
            if let old = cache.removeValue(forKey: key) { bytes -= old.value.cost }
        }
    }
    @discardableResult
    func request(_ hit: Hit, completion: @escaping (ThumbnailResult) -> Void) -> ThumbnailLoad {
        cancel(hit.identity)
        let job = ThumbnailLoad()
        lock.lock()
        jobs[hit.identity] = job
        lock.unlock()
        let operation = BlockOperation { [weak self, weak job] in
            guard let self, let job, !job.cancelled else { return }
            self.lock.lock()
            self.running += 1
            self.peak = max(self.peak, self.running)
            self.lock.unlock()
            let result = self.load(hit, job: job)
            self.lock.lock()
            self.running -= 1
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                let current = self.jobs[hit.identity] === job
                if current { self.jobs[hit.identity] = nil }
                self.lock.unlock()
                if current && !job.cancelled { completion(result) }
            }
        }
        job.operation = operation
        queue.addOperation(operation)
        return job
    }
    private func failure(_ text: String) -> ThumbnailResult { ThumbnailResult(image: nil, message: text) }
    private func stamp(_ path: String) -> (ContentSourceGeneration, UInt32)? {
        LocalContentAccess.withoutMaterialization(allowLegacy: false) {
            var status = stat()
            guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                return nil as (ContentSourceGeneration, UInt32)?
            }
            return (ContentSourceGeneration.from(status), status.st_flags)
        } ?? nil
    }
    private func validateLocalRoot(_ hit: Hit, job: ThumbnailLoad) -> Bool {
        guard let cli = cliPath ?? findCLI(), !job.cancelled else { return false }
        let object: [String: Any] = ["filesystemPath": hit.filesystemPath, "archiveMembers": [String]()]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else { return false }
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let diagnostics = SearchDiagnostics()
        child.executableURL = URL(fileURLWithPath: interpreter)
        child.arguments = [cli, "--local-only", "--extract-json", text]
        child.standardOutput = output
        child.standardError = errors
        diagnostics.collect(from: errors)
        job.attach(child)
        do { try child.run() } catch {
            diagnostics.finish(errors)
            return false
        }
        let until = Date().addingTimeInterval(2)
        while child.isRunning && !job.cancelled && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        diagnostics.finish(errors)
        return !job.cancelled && child.terminationStatus == 0 && result.count > 1 && result.count <= 16384
    }
    private func load(_ hit: Hit, job: ThumbnailLoad) -> ThumbnailResult {
        guard !hit.isDirectory, Self.extensions.contains((hit.displayName as NSString).pathExtension.lowercased())
        else { return failure(hit.isDirectory ? "Ordner" : "Keine Bildminiatur") }
        guard let (generation, flags) = stamp(hit.filesystemPath) else { return failure("Lokal nicht lesbar") }
        guard flags & 0x4000_0000 == 0 else { return failure("Nicht lokal verfügbar") }
        if let size = UInt64(generation.size),
            size > UInt64(hit.isMember ? Self.maximumContainerBytes : Self.maximumBytes)
        {
            return failure(hit.isMember ? "Archiv über 256 MiB" : "Bilddatei über 64 MiB")
        }
        if let expected = hit.documentSourceGeneration ?? hit.contentPreview?.sourceGeneration, expected != generation {
            return failure("Quelle geändert — neu suchen")
        }
        if let value = cached(hit, generation: generation) { return value }
        guard !job.cancelled, validateLocalRoot(hit, job: job) else {
            return failure("Lokal nicht lesbar / Provider unbekannt")
        }
        var url = URL(fileURLWithPath: hit.filesystemPath)
        var request: MaterializationRequest?
        defer { request?.release() }
        if hit.isMember {
            if let size = hit.size, size > Self.maximumBytes { return failure("Bilddatei über 64 MiB") }
            let done = DispatchSemaphore(value: 0)
            var outcome: MaterializationOutcome?
            request = manager.request(
                hit, localOnly: true, ephemeral: true
            ) { value in
                outcome = value
                done.signal()
            }
            job.attach(request)
            if done.wait(timeout: .now() + 5) != .success {
                request?.cancel()
                return failure("Miniatur-Zeitgrenze erreicht")
            }
            guard !job.cancelled, case .ready(let ready)? = outcome else {
                request?.release()
                return failure("Archivminiatur nicht verfügbar")
            }
            url = ready
        }
        guard !job.cancelled else { return failure("Miniatur abgebrochen") }
        let value =
            LocalContentAccess.withoutMaterialization(allowLegacy: false) { () -> ThumbnailResult in
                let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
                guard descriptor >= 0 else { return self.failure("Lokal nicht lesbar") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var status = stat()
                guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    return self.failure("Keine reguläre Bilddatei")
                }
                let leaf = ContentSourceGeneration.from(status)
                guard status.st_size <= Self.maximumBytes, status.st_flags & 0x4000_0000 == 0 else {
                    return self.failure("Nicht lokal oder über 64 MiB")
                }
                if !hit.isMember && leaf != generation { return self.failure("Quelle geändert — neu suchen") }
                var data = Data()
                let until = Date().addingTimeInterval(2)
                do {
                    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                        guard !job.cancelled, Date() < until, data.count + chunk.count <= Self.maximumBytes else {
                            return self.failure("Miniaturgrenze erreicht")
                        }
                        data.append(chunk)
                    }
                } catch { return self.failure("Bild nicht lesbar") }
                guard fstat(descriptor, &status) == 0, ContentSourceGeneration.from(status) == leaf,
                    self.stamp(hit.filesystemPath)?.0 == generation
                else { return self.failure("Quelle geändert — neu suchen") }
                return Self.decode(data)
            } ?? failure("Lokale Miniaturen benötigen macOS 13+")
        guard !job.cancelled else { return failure("Miniatur abgebrochen") }
        if value.image != nil {
            lock.lock()
            decoded += 1
            lock.unlock()
        }
        store(value, hit: hit, generation: generation)
        return value
    }
    static func decode(_ data: Data) -> ThumbnailResult {
        func failure(_ text: String) -> ThumbnailResult { ThumbnailResult(image: nil, message: text) }
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?,
            [
                "public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif", "public.heic",
                "public.heif", "org.webmproject.webp", "public.webp",
            ].contains(type),
            CGImageSourceGetCount(source) <= 1024,
            let facts = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = facts[kCGImagePropertyPixelWidth as String] as? Int,
            let height = facts[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0, width <= 16384, height <= 16384, width * height <= maximumPixels,
            let depth = facts[kCGImagePropertyDepth as String] as? Int, (1...16).contains(depth)
        else { return failure("Bild nicht lesbar / Pixelgrenze") }
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixelEdge,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return failure("Bild nicht lesbar") }
        return ThumbnailResult(image: image, message: CGImageSourceGetCount(source) > 1 ? "Erster Bildframe" : "")
    }
}

final class HitResultTableView: NSTableView {
    var onReload: (() -> Void)?
    override func reloadData() {
        super.reloadData()
        onReload?()
    }
}

final class ThumbnailTileView: NSView {
    var onAppearance: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }
}

final class ThumbnailTile: NSCollectionViewItem {
    let picture = NSImageView(), name = NSTextField(wrappingLabelWithString: ""),
        detail = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
    var identity: HitIdentity?
    private(set) var hasThumbnailResult = false
    private var renderRevision = -1
    override func loadView() {
        let tileView = ThumbnailTileView()
        view = tileView
        tileView.onAppearance = { [weak self] in self?.updateColors() }
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        picture.imageScaling = .scaleProportionallyUpOrDown
        name.maximumNumberOfLines = 2
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        for label in [detail, status] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for child in [picture, name, detail, status] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            picture.heightAnchor.constraint(equalToConstant: 96),
            name.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            name.heightAnchor.constraint(equalToConstant: 30),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            status.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: name.trailingAnchor),
        ])
    }
    override var isSelected: Bool { didSet { updateColors() } }
    func updateColors() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor =
                (isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22) : NSColor.controlBackgroundColor)
                .cgColor
            view.layer?.borderWidth = isSelected ? 2 : 1
            view.layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    func configure(_ hit: Hit, revision: Int) {
        guard identity != hit.identity || renderRevision != revision else { return }
        renderRevision = revision
        identity = hit.identity
        hasThumbnailResult = false
        name.stringValue = hit.displayName
        name.toolTip = hit.path
        view.toolTip = hit.path
        detail.stringValue =
            hit.size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " · " + hit.typeDescription
            } ?? hit.typeDescription
        picture.image = NSImage(
            systemSymbolName: hit.isDirectory ? "folder" : "photo",
            accessibilityDescription: hit.isDirectory ? "Ordner" : "Bildminiatur")
        picture.contentTintColor = .tertiaryLabelColor
        status.stringValue = "Lade Miniatur…"
        updateColors()
        view.setAccessibilityIdentifier("thumbnail-" + hit.displayName)
        view.setAccessibilityLabel(hit.displayName)
    }
    func apply(_ result: ThumbnailResult) {
        hasThumbnailResult = true
        picture.image =
            result.image.map { NSImage(cgImage: $0, size: .zero) }
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Keine Miniatur")
        picture.contentTintColor = result.image == nil ? .tertiaryLabelColor : nil
        status.stringValue = result.message
        status.toolTip = result.message
    }
}

final class ThumbnailHeader: NSView, NSCollectionViewElement {
    func setContent(_ content: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

final class ThumbnailCollectionView: NSCollectionView {
    weak var coordinator: ThumbnailGridController?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point), let hit = coordinator?.hitIndex(index),
            let owner = coordinator?.owner
        else { return nil }
        coordinator?.contextTableRow = owner.tableRow(forHitIndex: hit) ?? -1
        return owner.tableView.menu
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            coordinator?.owner?.contextRow = -1
            coordinator?.owner?.ctxOpen()
        }
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.width != size.width
        super.setFrameSize(size)
        if changed {
            collectionViewLayout?.invalidateLayout()
            coordinator?.scheduleVisible()
        }
    }
}

final class ThumbnailGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    weak var owner: HitListController?
    let collection = ThumbnailCollectionView(), loader = ThumbnailLoader()
    let sortPopup = NSPopUpButton()
    let modeControl = NSSegmentedControl(
        labels: ["Tabelle", "Miniaturen"], trackingMode: .selectOne, target: nil, action: nil)
    private weak var scroll: NSScrollView?
    private let compact: Bool
    private var originalHorizontal = false, syncing = false, visibleScheduled = false
    private var sections: [(group: ResultGroup?, indices: [Int])] = []
    private var demands = Set<HitIdentity>()
    private var renderRevision = 0
    private var observers: [NSObjectProtocol] = []
    private(set) var isGrid = false
    var contextTableRow = -1
    init(owner: HitListController, scroll: NSScrollView, compact: Bool) {
        self.owner = owner
        self.scroll = scroll
        self.compact = compact
        originalHorizontal = scroll.hasHorizontalScroller
        super.init()
        collection.coordinator = self
        collection.dataSource = self
        collection.delegate = self
        collection.allowsEmptySelection = true
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.controlBackgroundColor]
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.prefetchDataSource = nil
        collection.autoresizingMask = [.width]
        collection.setAccessibilityIdentifier("thumbnail-grid")
        collection.setAccessibilityLabel("Treffer als Miniaturen")
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: compact ? 144 : 160, height: 180)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.register(ThumbnailTile.self, forItemWithIdentifier: .init("tile"))
        collection.register(
            ThumbnailHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: .init("header"))
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier("resultViewMode")
        modeControl.setAccessibilityLabel("Trefferdarstellung")
        if compact {
            for (index, symbol) in ["list.bullet", "square.grid.2x2"].enumerated() {
                modeControl.setLabel("", forSegment: index)
                modeControl.setImage(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: index == 0 ? "Tabelle" : "Miniaturen"),
                    forSegment: index)
                modeControl.setWidth(28, forSegment: index)
                modeControl.setToolTip(index == 0 ? "Tabelle" : "Miniaturen", forSegment: index)
            }
        }
        for column in owner.tableView.tableColumns {
            if let prototype = column.sortDescriptorPrototype, let key = prototype.key {
                for ascending in [true, false] {
                    sortPopup.addItem(withTitle: column.title + (ascending ? " ↑" : " ↓"))
                    sortPopup.lastItem?.representedObject = NSSortDescriptor(key: key, ascending: ascending)
                }
            }
        }
        sortPopup.addItem(withTitle: "Ohne Sortierung")
        sortPopup.select(sortPopup.lastItem)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.setAccessibilityIdentifier("thumbnailSort")
        sortPopup.setAccessibilityLabel("Treffer sortieren")
        sortPopup.toolTip = "Sortierung derselben Treffer wie im Tabellenkopf"
        owner.resultGrouping.view.addArrangedSubview(sortPopup)
        owner.resultGrouping.view.addArrangedSubview(modeControl)
        sortPopup.isHidden = true
        owner.tableView.onReload = { [weak self] in self?.reload() }
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in self?.scheduleVisible() })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: owner.window, queue: .main
            ) { [weak self] _ in self?.scheduleVisible() })
        if UserDefaults.standard.bool(forKey: "resultView.thumbnails") { setGrid(true, persist: false) }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        loader.cancelAll(clearCache: true)
    }
    @objc private func sortChanged() {
        let descriptor = sortPopup.selectedItem?.representedObject as? NSSortDescriptor
        owner?.tableView.sortDescriptors = descriptor.map { [$0] } ?? []
    }
    @objc private func modeChanged() { setGrid(modeControl.selectedSegment == 1) }
    func setGrid(_ active: Bool, persist: Bool = true) {
        guard let owner, let scroll, active != isGrid else { return }
        owner.contextRow = -1
        contextTableRow = -1
        loader.cancelAll()
        demands.removeAll()
        isGrid = active
        modeControl.selectedSegment = active ? 1 : 0
        sortPopup.isHidden = !active
        if persist { UserDefaults.standard.set(active, forKey: "resultView.thumbnails") }
        scroll.documentView = active ? collection : owner.tableView
        scroll.hasHorizontalScroller = active ? false : originalHorizontal
        if active {
            collection.frame = NSRect(origin: .zero, size: scroll.contentSize)
            reload()
        } else {
            owner.window?.makeFirstResponder(owner.tableView)
        }
        if active { owner.window?.makeFirstResponder(collection) }
    }
    func reload() {
        guard let owner else { return }
        loader.cancelAll()
        demands.removeAll()
        loader.prune(to: Set(owner.hits.map(\.identity)))
        sortPopup.select(sortPopup.lastItem)
        if let sort = owner.tableView.sortDescriptors.first,
            let item = sortPopup.itemArray.first(where: {
                guard let value = $0.representedObject as? NSSortDescriptor else { return false }
                return value.key == sort.key && value.ascending == sort.ascending
            })
        {
            sortPopup.select(item)
        }
        let projection = owner.resultGrouping.projection
        sections =
            projection.mode == .none
            ? [(nil, Array(owner.hits.indices))]
            : projection.groups.map { ($0, $0.hitIndices.filter { projection.tableRow(for: $0) != nil }) }
        guard isGrid else { return }
        syncing = true
        renderRevision += 1
        collection.reloadData()
        selectionFromTable()
        syncing = false
        collection.layoutSubtreeIfNeeded()
        scheduleVisible()
    }
    func selectionFromTable() {
        guard isGrid, let owner else { return }
        let selected = Set(owner.selectedHitIndices)
        let previous = syncing
        syncing = true
        collection.selectionIndexPaths = Set(
            sections.enumerated().flatMap { section, value in
                value.indices.enumerated().compactMap { item, index in
                    selected.contains(index) ? IndexPath(item: item, section: section) : nil
                }
            })
        syncing = previous
    }
    func hitIndex(_ index: IndexPath) -> Int? {
        guard sections.indices.contains(index.section), sections[index.section].indices.indices.contains(index.item)
        else { return nil }
        return sections[index.section].indices[index.item]
    }
    func reveal(_ identity: HitIdentity) {
        guard isGrid, let owner else { return }
        for (section, value) in sections.enumerated() {
            if let item = value.indices.firstIndex(where: { owner.hits[$0].identity == identity }) {
                collection.scrollToItems(
                    at: [IndexPath(item: item, section: section)], scrollPosition: .nearestVerticalEdge)
                return
            }
        }
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].indices.count : 0
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt index: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: .init("tile"), for: index) as! ThumbnailTile
        if let owner, let hit = hitIndex(index), owner.hits.indices.contains(hit) { item.configure(owner.hits[hit], revision: renderRevision) }
        return item
    }
    func collectionView(
        _ view: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at index: IndexPath
    ) -> NSView {
        let header =
            view.makeSupplementaryView(ofKind: kind, withIdentifier: .init("header"), for: index) as! ThumbnailHeader
        if let group = sections[index.section].group, let owner {
            header.setContent(owner.resultGrouping.headerContent(group))
        }
        return header
    }
    func collectionView(
        _ view: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int
    ) -> NSSize { sections[section].group == nil ? .zero : NSSize(width: view.bounds.width, height: 28) }
    private func select() {
        guard !syncing, let owner else { return }
        owner.contextRow = -1
        contextTableRow = -1
        owner.tableView.selectRowIndexes(
            IndexSet(
                collection.selectionIndexPaths.compactMap { hitIndex($0) }.compactMap {
                    owner.tableRow(forHitIndex: $0)
                }), byExtendingSelection: false)
        owner.refreshContentPreview()
    }
    func collectionView(_ view: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { select() }
    func collectionView(_ view: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { select() }
    func collectionView(_ view: NSCollectionView, pasteboardWriterForItemAt index: IndexPath) -> NSPasteboardWriting? {
        guard let hit = hitIndex(index) else { return nil }
        return owner?.hitPasteboardWriter(hit)
    }
    func collectionView(
        _ view: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt index: IndexPath
    ) { scheduleVisible() }
    func collectionView(
        _ view: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt index: IndexPath
    ) { scheduleVisible() }
    func scheduleVisible() {
        guard !visibleScheduled else { return }
        visibleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleScheduled = false
            self.loadVisible()
        }
    }
    private func loadVisible() {
        guard isGrid, let owner, owner.window?.isVisible == true else {
            loader.cancelAll()
            demands.removeAll()
            return
        }
        var visible: [(ThumbnailTile, Hit)] = []
        for item in collection.visibleItems() {
            guard let tile = item as? ThumbnailTile, let index = collection.indexPath(for: item),
                let hitIndex = hitIndex(index), owner.hits.indices.contains(hitIndex),
                collection.layoutAttributesForItem(at: index)?.frame.intersects(collection.visibleRect) == true
            else { continue }
            visible.append((tile, owner.hits[hitIndex]))
        }
        let wanted = Set(visible.map { $0.1.identity })
        for identity in demands.subtracting(wanted) { loader.cancel(identity) }
        demands.formIntersection(wanted)
        for (tile, hit) in visible where !tile.hasThumbnailResult && !demands.contains(hit.identity) {
            guard loader.state["pending", default: 0] < 16 else { break }
            demands.insert(hit.identity)
            loader.request(hit) { [weak self] result in
                guard let self else { return }
                self.demands.remove(hit.identity)
                for case let current as ThumbnailTile in self.collection.visibleItems()
                    where current.identity == hit.identity {
                    current.apply(result)
                }
                self.scheduleVisible()
            }
        }
    }
}
