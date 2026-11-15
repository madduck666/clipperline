import AppKit
import QuickLookThumbnailing

/// Session-only references. Dismissing the shelf never touches source files.
@MainActor final class DropShelf {
    private(set) var files: [URL] = []
    func add(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= 100 else { throw CocoaError(.fileReadInvalidFileName) }
        let candidates = try urls.map { url -> URL in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw CocoaError(.fileReadUnsupportedScheme) }
            let canonical = url.standardizedFileURL
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            return canonical
        }
        var next = files
        for url in candidates where !next.contains(url) { next.append(url) }
        guard next.count <= 100 else { throw CocoaError(.fileReadTooLarge) }
        files = next
    }
    func dragFiles() throws -> [URL] {
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        for file in files { guard try file.checkResourceIsReachable() else { throw CocoaError(.fileNoSuchFile) } }
        return files
    }
    func clear() { files.removeAll() }

    static func placement(area: NSRect, pointer: NSPoint, obstacles: [NSRect]) -> NSRect {
        let width = min(216.0, area.width), height = min(228.0, area.height), margin = 16.0
        var xs = [area.minX + margin, area.maxX - width - margin]
        var ys = [area.minY + margin, area.maxY - height - margin]
        for rect in obstacles {
            xs += [rect.minX - width - margin, rect.maxX + margin]
            ys += [rect.minY - height - margin, rect.maxY + margin]
        }
        let cursor = NSRect(x: pointer.x - 48, y: pointer.y - 48, width: 96, height: 96)
        func overlap(_ a: NSRect, _ b: NSRect) -> Double {
            let intersection = a.intersection(b)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        var best = NSRect(x: area.minX, y: area.minY, width: width, height: height), score = Double.infinity
        for x in xs { for y in ys {
            let rect = NSRect(x: max(area.minX, min(area.maxX - width, x)).rounded(), y: max(area.minY, min(area.maxY - height, y)).rounded(), width: width, height: height)
            let next = obstacles.reduce(0) { $0 + overlap(rect, $1) } + overlap(rect, cursor) * 1000 + hypot(rect.midX - pointer.x, rect.midY - pointer.y) * 0.001
            if next < score { best = rect; score = next }
        } }
        return best
    }
}

/// The panel can appear after an external drag has already begun. Register the
/// window itself as a destination as well as its view, so AppKit has a fallback
/// across the nonactivating panel's frame and material-backed surface.
@MainActor final class DropShelfPanel: NSPanel, NSDraggingDestination {
    private var destination: DropShelfView? { contentView as? DropShelfView }
    init(content: DropShelfView) {
        super.init(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = content; isOpaque = false; backgroundColor = .clear
        hasShadow = true; level = .floating; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false; ignoresMouseEvents = false
        registerForDraggedTypes([.fileURL])
    }
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingEntered(sender) ?? [] }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingUpdated(sender) ?? [] }
    func draggingExited(_ sender: NSDraggingInfo?) { destination?.draggingExited(sender) }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.prepareForDragOperation(sender) ?? false }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.performDragOperation(sender) ?? false }
    func concludeDragOperation(_ sender: NSDraggingInfo?) { destination?.concludeDragOperation(sender) }
}

@MainActor final class DropShelfController {
    let model = DropShelf()
    private var timer: Timer?
    private var lastChange = NSPasteboard(name: .drag).changeCount
    private var active = false
    private var generation = 0
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private lazy var view: DropShelfView = {
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        view.onDrop = { [weak self] urls in self?.accept(urls) ?? false }
        view.onClose = { [weak self] in self?.dismiss() }
        view.dragFiles = { [weak self] in try self?.model.dragFiles() ?? [] }
        return view
    }()
    private lazy var panel = DropShelfPanel(content: view)
    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard(name: .drag).changeCount
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        dismiss()
    }
    private func poll() {
        let board = NSPasteboard(name: .drag), down = NSEvent.pressedMouseButtons & 1 != 0
        if !down {
            lastChange = board.changeCount
            if active {
                active = false
                let current = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.generation == current, !self.active, self.model.files.isEmpty else { return }
                    self.panel.orderOut(nil)
                }
            }
            return
        }
        guard !active, board.changeCount != lastChange,
              board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        active = true; lastChange = board.changeCount; reveal()
    }
    func reveal() {
        generation += 1
        guard !panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        // CG window geometry is available without reading window contents/titles.
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let obstacles = windows.prefix(64).compactMap { info -> NSRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        panel.setFrame(DropShelf.placement(area: screen.visibleFrame, pointer: point, obstacles: obstacles), display: true)
        panel.orderFrontRegardless()
    }
    @discardableResult func accept(_ urls: [URL]) -> Bool {
        do {
            try model.add(urls); generation += 1
            view.files = model.files; view.message = ""; view.needsDisplay = true
            if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
            guard let first = model.files.first else { return false }
            view.preview = NSWorkspace.shared.icon(forFile: first.path)
            let current = generation
            let request = QLThumbnailGenerator.Request(fileAt: first, size: NSSize(width: 104, height: 104), scale: panel.backingScaleFactor, representationTypes: .thumbnail)
            thumbnailRequest = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == current, let representation else { return }
                    self.view.preview = representation.nsImage; self.view.needsDisplay = true
                }
            }
            return true
        } catch { view.message = L("A dropped file is no longer available."); view.needsDisplay = true; return false }
    }
    func dismiss() {
        generation += 1; model.clear(); view.files = []; view.preview = nil; view.message = ""
        panel.orderOut(nil); view.needsDisplay = true
    }
}

@MainActor final class DropShelfView: NSVisualEffectView, NSDraggingSource {
    var onDrop: (([URL]) -> Bool)?
    var onClose: (() -> Void)?
    var dragFiles: (() throws -> [URL])?
    var files: [URL] = []
    var preview: NSImage?
    var message = ""
    private var hovering = false
    private var down: NSPoint?
    private let closeButton = NSButton()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 25; layer?.masksToBounds = true
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel(L("Drop shelf"))
        closeButton.title = "×"; closeButton.bezelStyle = .circular
        closeButton.frame = NSRect(x: 9, y: frameRect.height - 37, width: 28, height: 28)
        closeButton.autoresizingMask = [.minYMargin]; closeButton.target = self; closeButton.action = #selector(closeShelf)
        closeButton.setAccessibilityLabel(L("Close")); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func closeShelf() { onClose?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Behind-window blur is composed by WindowServer. Give the entire
        // rounded surface real backing pixels too, so blank areas of this
        // transparent window do not become pointer/drag pass-through holes.
        NSColor.windowBackgroundColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 25, yRadius: 25).fill()
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.height - 13, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()
        if hovering { NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); bounds.fill() }
        let image = preview ?? NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        image?.draw(in: NSRect(x: bounds.midX - 50, y: 80, width: 100, height: 100), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        func label(_ text: String, y: Double, size: Double, color: NSColor) {
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(in: NSRect(x: 12, y: y, width: bounds.width - 24, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
        }
        label(files.count == 1 ? files[0].lastPathComponent : L("Drop shelf"), y: 53, size: 13, color: .labelColor)
        label(files.isEmpty ? L("Drop files here") : L("Drag to another window"), y: 31, size: 11, color: .secondaryLabelColor)
        if !message.isEmpty { label(message, y: 10, size: 10, color: .systemOrange) }
        else if files.count > 1 { label("\(files.count)", y: 10, size: 11, color: .secondaryLabelColor) }
    }
    private func dropURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard (sender.draggingSource as? DropShelfView) !== self,
              sender.draggingSourceOperationMask.contains(.copy),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.count <= 100 else { return nil }
        return urls
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = dropURLs(from: sender) != nil; needsDisplay = true
        return hovering ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Revalidate at mouse-up as well as during hover, before importing.
        // The source may have changed its payload or permitted operations.
        dropURLs(from: sender) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false; needsDisplay = true
        guard let urls = dropURLs(from: sender) else { return false }
        return onDrop?(urls) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y > bounds.height - 38 { window?.performDrag(with: event) }
        else { down = point }
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        down = nil
        do {
            let urls = try dragFiles?() ?? []
            guard !urls.isEmpty else { return }
            let items = urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(NSRect(x: point.x + Double(index % 3) * 4, y: point.y - 32, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        } catch { message = L("A dropped file is no longer available."); needsDisplay = true }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
