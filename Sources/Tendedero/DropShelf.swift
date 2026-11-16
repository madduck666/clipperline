import AppKit
import QuickLookThumbnailing

/// What the box shows for its current contents. Derived from stored URLs and
/// the last message only: no file I/O, so it is safe inside drag callbacks.
struct DropShelfDisplay: Equatable {
    var symbol: String
    var title: String
    var subtitle: String
    var detail: String
    var isWarning: Bool
}

/// Session-only references. Dismissing the shelf never touches source files.
@MainActor final class DropShelf {
    private(set) var files: [URL] = []
    func add(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.count <= 100 else { throw CocoaError(.fileReadInvalidFileName) }
        let candidates = try urls.map { url -> URL in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw CocoaError(.fileReadUnsupportedScheme) }
            // Finder may hand over file reference URLs (file:///.file/id=…),
            // whose last path component is an inode id, not the file's name.
            let canonical = ((url as NSURL).filePathURL ?? url).standardizedFileURL
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

    /// After a drag out of the box ends. A move (Finder, same volume, no
    /// Option key) takes the dragged items out of the box; a copy or a
    /// cancelled drag keeps them. Either way, an item whose file is no longer
    /// at its stored location leaves the box.
    func finishDrag(dragged: [URL], operation: NSDragOperation, exists: (URL) -> Bool) {
        files = DropShelf.filesAfterDrag(files, dragged: dragged, operation: operation, exists: exists)
    }

    /// Outside the app, Finder may move (same volume) or copy (other volume,
    /// or Option held). Inside the app only a copy makes sense.
    nonisolated static func dragOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : [.copy, .move]
    }

    nonisolated static func filesAfterDrag(_ stored: [URL], dragged: [URL], operation: NSDragOperation, exists: (URL) -> Bool) -> [URL] {
        let kept = operation.contains(.move) ? stored.filter { !dragged.contains($0) } : stored
        return kept.filter { exists($0) }
    }

    /// Empty: a drop hint. One item: its name. Several: "N items". A message
    /// (rejected or unreadable drop) is shown in addition, never instead.
    static func display(files: [URL], message: String) -> DropShelfDisplay {
        guard let first = files.first else {
            return DropShelfDisplay(symbol: "tray.and.arrow.down", title: L("Drop files here"), subtitle: L("Drop shelf"),
                                    detail: message, isWarning: !message.isEmpty)
        }
        let folders = files.allSatisfy { $0.hasDirectoryPath }
        let symbol = files.count == 1 ? (first.hasDirectoryPath ? "folder" : "doc") : (folders ? "folder" : "doc.on.doc")
        let name = first.lastPathComponent.isEmpty ? first.path : first.lastPathComponent
        let title = files.count == 1 ? name : String(format: L("%d items"), files.count)
        return DropShelfDisplay(symbol: symbol, title: title, subtitle: L("Drag to another window"),
                                detail: message, isWarning: !message.isEmpty)
    }

    /// Largest rect with the image's aspect ratio, centred in `box`.
    nonisolated static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// The box opens beside the pointer, near enough to reach while the drag
    /// is still held: to the right by default, else left, below or above.
    /// It stays inside the visible frame (never under the menu bar or Dock)
    /// and never under the pointer itself.
    nonisolated static func placement(area: NSRect, pointer: NSPoint) -> NSRect {
        let width: CGFloat = min(216, area.width), height: CGFloat = min(228, area.height)
        let gap: CGFloat = 32, margin: CGFloat = 8
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            high < low ? (low + high) / 2 : min(max(value, low), high)
        }
        func fit(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: clamp(x, area.minX + margin, area.maxX - width - margin).rounded(),
                   y: clamp(y, area.minY + margin, area.maxY - height - margin).rounded(),
                   width: width, height: height)
        }
        func clearance(_ rect: NSRect) -> CGFloat {
            let dx = max(rect.minX - pointer.x, 0, pointer.x - rect.maxX)
            let dy = max(rect.minY - pointer.y, 0, pointer.y - rect.maxY)
            return hypot(dx, dy)
        }
        let candidates: [NSRect] = [
            fit(pointer.x + gap, pointer.y - height / 2),
            fit(pointer.x - gap - width, pointer.y - height / 2),
            fit(pointer.x - width / 2, pointer.y - gap - height),
            fit(pointer.x - width / 2, pointer.y + gap),
        ]
        if let near = candidates.first(where: { clearance($0) >= gap / 2 }) { return near }
        return candidates.max(by: { clearance($0) < clearance($1) }) ?? candidates[0]
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
        view.dragFiles = { [weak self] in
            guard let self else { return [] }
            do { return try self.model.dragFiles() } catch {
                // A stored file was moved or deleted elsewhere: drop the stale
                // entries so the next drag carries what is still there.
                self.dragEnded([], operation: [])
                throw error
            }
        }
        view.onDragEnded = { [weak self] urls, operation in self?.dragEnded(urls, operation: operation) }
        return view
    }()
    private lazy var panel = DropShelfPanel(content: view)
    #if DROP_SHELF_NATIVE_DIAGNOSTICS
    var nativeSourceDiagnostics: [String: Int] {
        guard !model.files.isEmpty else { return [:] }
        return ["sourceMouseDowns": view.nativeMouseDowns, "sourceDownY": view.nativeDownY,
                "sourceAttempts": view.nativeSourceAttempts, "sourceStarts": view.nativeSourceStarts,
                "sourceFailures": view.nativeSourceFailures]
    }
    #endif
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
              board.types?.contains(.fileURL) == true else { return }
        active = true; lastChange = board.changeCount; reveal()
    }
    func reveal() {
        guard !panel.isVisible else { return }
        generation += 1
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        if model.files.isEmpty { view.message = ""; view.needsDisplay = true }
        panel.setFrame(DropShelf.placement(area: screen.visibleFrame, pointer: point), display: true)
        panel.orderFrontRegardless()
    }
    @discardableResult func accept(_ urls: [URL]) -> Bool {
        do {
            try model.add(urls)
            guard !model.files.isEmpty else { return false }
            showFiles()
            return true
        } catch { view.message = L("A dropped file is no longer available."); view.needsDisplay = true; return false }
    }
    /// A drag out of the box ended. Runs after AppKit has finished the
    /// session; an emptied box hides exactly as the close button hides it.
    func dragEnded(_ dragged: [URL], operation: NSDragOperation) {
        let before = model.files
        model.finishDrag(dragged: dragged, operation: operation, exists: { FileManager.default.fileExists(atPath: $0.path) })
        guard model.files != before else { return }
        if model.files.isEmpty { dismiss() } else { showFiles() }
    }
    private func showFiles() {
        generation += 1
        // File-specific icons can synchronously wait on IconServices or
        // protected-folder access. Finish the drop with the view's own symbol,
        // name and count (no I/O); the real preview replaces the symbol later.
        // A stale or failed preview leaves the symbol in place.
        view.files = model.files; view.message = ""; view.preview = nil; view.needsDisplay = true
        guard let first = model.files.first else { return }
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current else { return }
            if let request = self.thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
            let request = QLThumbnailGenerator.Request(fileAt: first, size: NSSize(width: 104, height: 104), scale: self.panel.backingScaleFactor, representationTypes: .all)
            self.thumbnailRequest = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == current, let representation,
                          representation.nsImage.size.width > 0, representation.nsImage.size.height > 0 else { return }
                    self.view.preview = representation.nsImage; self.view.needsDisplay = true
                }
            }
        }
    }
    func dismiss() {
        generation += 1; model.clear(); view.files = []; view.preview = nil; view.message = ""
        panel.orderOut(nil); view.needsDisplay = true
    }
}

/// A plain layer-backed view, not an NSVisualEffectView: custom drawing in a
/// visual-effect view's draw(_:) lands beneath its material layers, which left
/// the box showing only the dark material and the close button.
@MainActor final class DropShelfView: NSView, NSDraggingSource {
    var onDrop: (([URL]) -> Bool)?
    var onClose: (() -> Void)?
    var dragFiles: (() throws -> [URL])?
    var onDragEnded: (([URL], NSDragOperation) -> Void)?
    private var draggedFiles: [URL] = []
    var files: [URL] = []
    var preview: NSImage?
    var message = ""
    #if DROP_SHELF_NATIVE_DIAGNOSTICS
    // Fixture-only counters contain phases and operation flags, never file paths.
    private(set) var nativeEntries = 0
    private(set) var nativePreparations = 0
    private(set) var nativeDropAttempts = 0
    private(set) var nativeSourceMask: NSDragOperation = []
    private(set) var nativeMouseDowns = 0, nativeDownY = 0
    private(set) var nativeSourceAttempts = 0, nativeSourceStarts = 0, nativeSourceFailures = 0
    #endif
    private var hovering = false
    private var down: NSPoint?
    private let closeButton = NSButton()
    /// Fixed dark surface with explicit light content, independent of the
    /// system appearance, so text and symbols always contrast.
    private static let surfaceColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    private static let primaryTextColor = NSColor.white
    private static let secondaryTextColor = NSColor(white: 1, alpha: 0.72)
    var shelfDisplay: DropShelfDisplay { DropShelf.display(files: files, message: message) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = DropShelfView.surfaceColor.cgColor
        layer?.cornerRadius = 25; layer?.masksToBounds = true
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel(L("Drop shelf"))
        closeButton.title = "×"; closeButton.bezelStyle = .circular
        closeButton.frame = NSRect(x: 9, y: frameRect.height - 37, width: 28, height: 28)
        closeButton.autoresizingMask = [.minYMargin]; closeButton.target = self; closeButton.action = #selector(closeShelf)
        closeButton.setAccessibilityLabel(L("Close")); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func closeShelf() { onClose?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A faint or material-only fill can let blank-area drags pass through.
        // Keep every interior pixel opaque so WindowServer targets this panel
        // before any destination callback or protected-file read is required.
        DropShelfView.surfaceColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 25, yRadius: 25).fill()
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.height - 13, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()
        if hovering { NSColor.controlAccentColor.withAlphaComponent(0.3).setFill(); bounds.fill() }
        let state = shelfDisplay
        // Symbols are template images: drawn directly they come out black on
        // the dark surface. Tint them; real previews are drawn as they are.
        let box = NSRect(x: bounds.midX - 50, y: 80, width: 100, height: 100)
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            preview.draw(in: DropShelf.aspectFit(preview.size, in: box), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            drawSymbol(state.symbol, in: box, color: DropShelfView.primaryTextColor)
        }
        func label(_ text: String, y: Double, size: Double, weight: NSFont.Weight, color: NSColor) {
            guard !text.isEmpty else { return }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(in: NSRect(x: 12, y: y, width: bounds.width - 24, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        }
        label(state.title, y: 53, size: 13, weight: .semibold, color: DropShelfView.primaryTextColor)
        label(state.subtitle, y: 31, size: 11, weight: .regular, color: DropShelfView.secondaryTextColor)
        label(state.detail, y: 10, size: 10, weight: .medium, color: state.isWarning ? .systemOrange : DropShelfView.secondaryTextColor)
    }
    /// Draws a template symbol in `color`: the glyph is painted into its own
    /// transparency layer, then recoloured only where the glyph has pixels.
    private func drawSymbol(_ name: String, in box: NSRect, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)),
              let context = NSGraphicsContext.current else { return }
        let rect = DropShelf.aspectFit(symbol.size, in: box.insetBy(dx: 10, dy: 10))
        context.saveGraphicsState()
        context.cgContext.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.set()
        rect.fill(using: .sourceAtop)
        context.cgContext.endTransparencyLayer()
        context.restoreGraphicsState()
    }
    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        // Negotiate using metadata only. Finder can defer file data and access
        // to protected folders until the destination actually receives a drop.
        // A hover must not depend on materializing URLs or stat-ing Downloads.
        (sender.draggingSource as? DropShelfView) !== self &&
            sender.draggingSourceOperationMask.contains(.copy) &&
            sender.draggingPasteboard.types?.contains(.fileURL) == true
    }
    private func dropURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard canAccept(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.count <= 100 else { return nil }
        return urls
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        #if DROP_SHELF_NATIVE_DIAGNOSTICS
        nativeEntries += 1; nativeSourceMask = sender.draggingSourceOperationMask
        #endif
        hovering = canAccept(sender); needsDisplay = true
        return hovering ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        #if DROP_SHELF_NATIVE_DIAGNOSTICS
        nativePreparations += 1
        #endif
        // Revalidate the advertised type and operation, but wait for perform
        // before requesting the actual file URLs and their access grant.
        return canAccept(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        #if DROP_SHELF_NATIVE_DIAGNOSTICS
        nativeDropAttempts += 1
        #endif
        hovering = false; needsDisplay = true
        // A drop that delivers no usable file never leaves the box silent.
        guard let urls = dropURLs(from: sender), onDrop?(urls) == true else {
            if message.isEmpty, (sender.draggingSource as? DropShelfView) !== self {
                message = L("A dropped file is no longer available.")
            }
            return false
        }
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        #if DROP_SHELF_NATIVE_DIAGNOSTICS
        nativeMouseDowns += 1; nativeDownY = Int(point.y)
        #endif
        if point.y > bounds.height - 38 { window?.performDrag(with: event) }
        else { down = point }
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        down = nil
        #if DROP_SHELF_NATIVE_DIAGNOSTICS
        nativeSourceAttempts += 1
        #endif
        do {
            let urls = try dragFiles?() ?? []
            guard !urls.isEmpty else { return }
            let items = urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let image = index == 0 ? preview : nil
                let offset = CGFloat(min(index, 5) * 4)
                item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48), contents: image ?? NSImage(systemSymbolName: url.hasDirectoryPath ? "folder" : "doc", accessibilityDescription: nil))
                return item
            }
            #if DROP_SHELF_NATIVE_DIAGNOSTICS
            nativeSourceStarts += 1
            #endif
            draggedFiles = urls
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .stack
            // Released where nothing accepts it: the items fly back to the box.
            session.animatesToStartingPositionsOnCancelOrFail = true
        } catch {
            #if DROP_SHELF_NATIVE_DIAGNOSTICS
            nativeSourceFailures += 1
            #endif
            message = L("A dropped file is no longer available."); needsDisplay = true
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        DropShelf.dragOperationMask(for: context)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let urls = draggedFiles
        draggedFiles = []
        // Let AppKit finish the session before the box may hide.
        DispatchQueue.main.async { [weak self] in self?.onDragEnded?(urls, operation) }
    }
}
