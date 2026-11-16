import AppKit
import Quartz
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

/// One preview card of the box's stack, in the view's (unflipped)
/// coordinates. `rotation` is in degrees, counterclockwise.
struct DropShelfCard: Equatable {
    /// Side of a card when several files are held; thumbnails are requested
    /// at this size rather than the single preview's size.
    static let stackSide: CGFloat = 72
    /// Least share of a card's width that the card in front of it leaves
    /// uncovered: the next card sits at least this far to the right.
    static let stackReveal: CGFloat = 0.42
    var center: NSPoint
    var size: NSSize
    var rotation: CGFloat
    /// The card before rotation.
    var frame: NSRect {
        NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
    /// Smallest upright rect containing the rotated card.
    var boundingBox: NSRect {
        let radians = Double(rotation) * Double.pi / 180
        let c = CGFloat(abs(cos(radians))), s = CGFloat(abs(sin(radians)))
        let width = size.width * c + size.height * s, height = size.width * s + size.height * c
        return NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

/// Fixed sizes of the box: the compact view beside the pointer and the
/// larger file list.
enum DropShelfLayout {
    static let compactSize = NSSize(width: 216, height: 228)
    static let listSize = NSSize(width: 380, height: 300)
    static let listRowHeight: CGFloat = 40
}

/// What the actions menu (all files) and a file's context menu can do.
enum DropShelfAction: CaseIterable {
    case openWith, showInFinder, quickLook, airDrop, mail, remove
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
    /// Takes one entry off the shelf. The file itself is never touched.
    func remove(_ url: URL) { files = DropShelf.filesRemoving(url, from: files) }

    nonisolated static func filesRemoving(_ url: URL, from files: [URL]) -> [URL] {
        files.filter { $0 != url }
    }

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

    /// Empty: a drop hint. One item: its name. Several: "N items" (shown on
    /// the count pill, not as a line of text). A message (rejected or
    /// unreadable drop) is shown in addition, never instead.
    static func display(files: [URL], message: String) -> DropShelfDisplay {
        guard let first = files.first else {
            return DropShelfDisplay(symbol: "tray.and.arrow.down", title: L("Drop files here"), subtitle: L("Drop shelf"),
                                    detail: message, isWarning: !message.isEmpty)
        }
        let folders = files.allSatisfy { $0.hasDirectoryPath }
        let symbol = files.count == 1 ? (first.hasDirectoryPath ? "folder" : "doc") : (folders ? "folder" : "doc.on.doc")
        let name = first.lastPathComponent.isEmpty ? first.path : first.lastPathComponent
        let title = files.count == 1 ? name : String(format: L("%d items"), files.count)
        return DropShelfDisplay(symbol: symbol, title: title, subtitle: "", detail: message, isWarning: !message.isEmpty)
    }

    /// The count pill under the stack: only when several files are held.
    nonisolated static func pillTitle(count: Int) -> String? {
        count > 1 ? String(format: L("%d items"), count) : nil
    }

    /// Header of the file list: "N items", plus the total size once known.
    nonisolated static func listTitle(count: Int, totalBytes: Int64?) -> String {
        let items = String(format: L("%d items"), count)
        guard let totalBytes else { return items }
        return items + " · " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// The total, once every size has been read; nil before that (or when a
    /// size cannot be read), so a partial sum is never shown as the total.
    nonisolated static func totalBytes(_ sizes: [Int64?]) -> Int64? {
        guard !sizes.isEmpty, !sizes.contains(where: { $0 == nil }) else { return nil }
        return sizes.reduce(Int64(0)) { $0 + ($1 ?? 0) }
    }

    /// Bytes of a file, or of everything inside a folder or bundle. Reads the
    /// disk: call it off the main thread. Very large folders give nil.
    nonisolated static func diskSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey]) else { return nil }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? values.totalFileSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [], errorHandler: nil) else { return nil }
        var total: Int64 = 0, visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > 50_000 { return nil }
            if let entry = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), entry.isRegularFile == true {
                total += Int64(entry.fileSize ?? 0)
            }
        }
        return total
    }

    /// Which menu entries can be chosen for `count` files. Open With and
    /// Remove act on one file only (its context menu).
    nonisolated static func enabledActions(count: Int, canAirDrop: Bool, canMail: Bool) -> Set<DropShelfAction> {
        guard count > 0 else { return [] }
        var actions: Set<DropShelfAction> = [.showInFinder, .quickLook]
        if canAirDrop { actions.insert(.airDrop) }
        if canMail { actions.insert(.mail) }
        if count == 1 { actions.insert(.openWith); actions.insert(.remove) }
        return actions
    }

    /// Open With lists the default application first, each application once.
    nonisolated static func orderedApplications(_ all: [URL], preferred: URL?) -> [URL] {
        var seen = Set<String>(), result: [URL] = []
        let candidates = (preferred.map { [$0] } ?? []) + all
        for app in candidates {
            let key = app.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(app)
        }
        return result
    }

    /// While a shelf menu, Quick Look or a sharing service is open, the drag
    /// monitor neither hides nor moves the visible box.
    nonisolated static func monitorPaused(menuOpen: Bool, quickLookOpen: Bool, sharing: Bool, panelVisible: Bool) -> Bool {
        panelVisible && (menuOpen || quickLookOpen || sharing)
    }

    /// A box of `size` whose top-left corner stays at `topLeft` where it
    /// fits, moved just enough to stay `8` pt inside `area` otherwise.
    nonisolated static func panelFrame(size: NSSize, topLeft: NSPoint, in area: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let width = max(0, min(size.width, area.width - 2 * margin))
        let height = max(0, min(size.height, area.height - 2 * margin))
        let x = min(max(topLeft.x, area.minX + margin), area.maxX - margin - width)
        let top = min(max(topLeft.y, area.minY + margin + height), area.maxY - margin)
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// A thumbnail is drawn as its own card: its own proportions, as large
    /// as fits in the slot, centred.
    nonisolated static func framelessRect(imageSize: NSSize, in slot: NSRect) -> NSRect {
        aspectFit(imageSize, in: slot)
    }

    /// Largest rect with the image's aspect ratio, centred in `box`.
    nonisolated static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// Where previews are drawn: above the title, right of the close button,
    /// below the grab handle.
    nonisolated static func previewArea(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX - 70, y: 78, width: 140, height: 104)
    }

    /// The files shown as cards, back to front: the last four added, the
    /// most recently added last (in front).
    nonisolated static func stackFiles(_ files: [URL]) -> [URL] {
        Array(files.suffix(4))
    }

    /// One card: today's single 100 pt preview, upright and centred. Several:
    /// up to four smaller cards, back to front, spread left to right and
    /// fanned symmetrically (the left card tilts left, the right one right;
    /// the view is unflipped, so a positive angle turns counterclockwise).
    /// Cards shrink as needed so each card behind keeps `stackReveal` of its
    /// width visible. Every rotated card lies inside `area`.
    nonisolated static func stackLayout(count: Int, in area: NSRect) -> [DropShelfCard] {
        let n = min(max(count, 0), 4)
        guard n > 0, area.width > 0, area.height > 0 else { return [] }
        if n == 1 {
            let side = min(100, area.width, area.height)
            return [DropShelfCard(center: NSPoint(x: area.midX, y: area.midY), size: NSSize(width: side, height: side), rotation: 0)]
        }
        let angles: [CGFloat]
        switch n {
        case 2: angles = [6, -6]
        case 3: angles = [8, 0, -8]
        default: angles = [8, 3, -3, -8]
        }
        let radians = 8 * Double.pi / 180
        let spread = CGFloat(cos(radians) + sin(radians))
        let reveal = DropShelfCard.stackReveal
        let side = min(DropShelfCard.stackSide, area.height / spread, area.width / (spread + CGFloat(n - 1) * reveal))
        let step = max(0, min(side / 2, (area.width - side * spread) / CGFloat(n - 1)))
        return (0..<n).map { index in
            let offset = (CGFloat(index) - CGFloat(n - 1) / 2) * step
            return DropShelfCard(center: NSPoint(x: area.midX + offset, y: area.midY),
                                 size: NSSize(width: side, height: side), rotation: angles[index])
        }
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

/// A menu entry that runs a closure. The closure runs just after the menu
/// has closed, so it may change or remove the view the menu came from.
final class DropShelfMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() {
        let handler = self.handler
        DispatchQueue.main.async { handler() }
    }
}

/// Feeds the shelf's files to the shared Quick Look panel.
@MainActor final class DropShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    /// Left and right go to the previous or next file.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let panel else { return false }
        let step: Int
        switch Int(event.keyCode) {
        case 123: step = -1 // left arrow
        case 124: step = 1 // right arrow
        default: return false
        }
        return MainActor.assumeIsolated {
            let next = panel.currentPreviewItemIndex + step
            guard urls.indices.contains(next) else { return true }
            panel.currentPreviewItemIndex = next
            return true
        }
    }
}

/// Learns when AirDrop or Mail has finished with the shelf's files.
@MainActor final class DropShelfSharing: NSObject, NSSharingServiceDelegate {
    var onFinish: (() -> Void)?
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFinish?() }
    }
}

@MainActor final class DropShelfController {
    let model = DropShelf()
    private var timer: Timer?
    private var lastChange = NSPasteboard(name: .drag).changeCount
    private var active = false
    private var generation = 0
    private var thumbnailRequests: [QLThumbnailGenerator.Request] = []
    private var listRequests: [QLThumbnailGenerator.Request] = []
    /// The compact box's frame before the file list opened, and the list's
    /// own frame, so going back returns to where the box was.
    private var compactFrame: NSRect?
    private var listFrame: NSRect?
    private var menuOpen = false
    /// The AirDrop or Mail service in progress, kept alive until it reports.
    private var sharingService: NSSharingService?
    private let quickLook = DropShelfQuickLook()
    private lazy var sharing: DropShelfSharing = {
        let sharing = DropShelfSharing()
        sharing.onFinish = { [weak self] in self?.sharingService = nil }
        return sharing
    }()
    private lazy var view: DropShelfView = {
        let view = DropShelfView(frame: NSRect(origin: .zero, size: DropShelfLayout.compactSize))
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
        view.onShowList = { [weak self] in self?.showList() }
        view.onBack = { [weak self] in self?.showCompact() }
        view.onActions = { [weak self] button in self?.popUpActions(from: button) }
        view.onFileMenu = { [weak self] url, event, source in self?.popUpMenu(for: url, event: event, in: source) }
        view.onOpenFile = { url in _ = NSWorkspace.shared.open(url) }
        view.onRevealAll = { [weak self] in
            guard let self else { return }
            self.revealInFinder(self.model.files)
        }
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
    /// Whether the files view is showing.
    var isShowingList: Bool { view.mode == .list }
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
        for request in thumbnailRequests { QLThumbnailGenerator.shared.cancel(request) }
        thumbnailRequests = []
        dismiss()
    }
    private var quickLookOpen: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(), preview.isVisible else { return false }
        return preview.dataSource === quickLook
    }
    /// A shelf menu, the shelf's Quick Look or a sharing service is open.
    private var monitorPaused: Bool {
        DropShelf.monitorPaused(menuOpen: menuOpen, quickLookOpen: quickLookOpen, sharing: sharingService != nil, panelVisible: panel.isVisible)
    }
    private func poll() {
        let board = NSPasteboard(name: .drag), down = NSEvent.pressedMouseButtons & 1 != 0
        if monitorPaused { lastChange = board.changeCount; return }
        if !down {
            lastChange = board.changeCount
            if active {
                active = false
                let current = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.generation == current, !self.active, self.model.files.isEmpty, !self.monitorPaused else { return }
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
        view.setMode(.compact); compactFrame = nil; listFrame = nil
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
    /// "Remove from shelf": only that entry leaves; the file stays where it is.
    func remove(_ url: URL) {
        let before = model.files
        model.remove(url)
        guard model.files != before else { return }
        if model.files.isEmpty { dismiss() } else { showFiles() }
    }
    private func showFiles() {
        generation += 1
        // File-specific icons can synchronously wait on IconServices or
        // protected-folder access. Finish the drop with the view's own symbols,
        // name and count (no I/O); real previews replace the symbols later,
        // one per shown file. A stale or failed preview leaves its symbol.
        view.files = model.files; view.message = ""; view.preview = nil; view.previews = [:]; view.needsDisplay = true
        if view.mode == .list {
            if model.files.count < 2 { showCompact() } else { loadListDetails() }
        }
        let shown = DropShelf.stackFiles(model.files)
        guard !shown.isEmpty else { return }
        let single = shown.count == 1
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current else { return }
            for request in self.thumbnailRequests { QLThumbnailGenerator.shared.cancel(request) }
            self.thumbnailRequests = []
            let side: CGFloat = single ? 104 : DropShelfCard.stackSide
            let scale = single ? self.panel.backingScaleFactor : max(self.panel.backingScaleFactor, 2)
            for file in shown {
                let request = QLThumbnailGenerator.Request(fileAt: file, size: NSSize(width: side, height: side), scale: scale, representationTypes: .all)
                self.thumbnailRequests.append(request)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                    DispatchQueue.main.async {
                        guard let self, self.generation == current, let representation,
                              representation.nsImage.size.width > 0, representation.nsImage.size.height > 0 else { return }
                        if single { self.view.preview = representation.nsImage } else { self.view.previews[file] = representation.nsImage }
                        self.view.needsDisplay = true
                    }
                }
            }
        }
    }
    private func visibleArea() -> NSRect {
        if let screen = panel.screen ?? NSScreen.main { return screen.visibleFrame }
        return panel.frame.insetBy(dx: -1000, dy: -1000)
    }
    /// The count pill: the box grows into the file list, its top-left corner
    /// staying where it was unless the screen edge is in the way.
    func showList() {
        guard model.files.count > 1, view.mode == .compact else { return }
        let current = panel.frame
        let frame = DropShelf.panelFrame(size: DropShelfLayout.listSize, topLeft: NSPoint(x: current.minX, y: current.maxY), in: visibleArea())
        compactFrame = current; listFrame = frame
        view.setMode(.list)
        panel.setFrame(frame, display: true)
        loadListDetails()
    }
    /// Back: the compact box returns to its earlier place and size (or, if
    /// the list was moved, to the list's top-left corner).
    func showCompact() {
        guard view.mode == .list else { return }
        for request in listRequests { QLThumbnailGenerator.shared.cancel(request) }
        listRequests = []
        let current = panel.frame
        let anchor: NSPoint
        if let compactFrame, current == listFrame {
            anchor = NSPoint(x: compactFrame.minX, y: compactFrame.maxY)
        } else {
            anchor = NSPoint(x: current.minX, y: current.maxY)
        }
        compactFrame = nil; listFrame = nil
        view.setMode(.compact)
        panel.setFrame(DropShelf.panelFrame(size: DropShelfLayout.compactSize, topLeft: anchor, in: visibleArea()), display: true)
    }
    /// Thumbnails for every listed file, and their sizes, read off the main
    /// thread; both arrive later and only for the current contents.
    private func loadListDetails() {
        for request in listRequests { QLThumbnailGenerator.shared.cancel(request) }
        listRequests = []
        let current = generation
        let files = model.files
        let scale = max(panel.backingScaleFactor, 2)
        for file in files {
            let request = QLThumbnailGenerator.Request(fileAt: file, size: NSSize(width: 32, height: 32), scale: scale, representationTypes: .all)
            listRequests.append(request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == current, let representation,
                          representation.nsImage.size.width > 0, representation.nsImage.size.height > 0 else { return }
                    self.view.listView.setImage(representation.nsImage, for: file)
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sizes = files.map { DropShelf.diskSize(of: $0) }
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.model.files == files else { return }
                self.view.listView.setSizes(sizes, for: files)
            }
        }
    }
    private func popUpActions(from button: NSView) {
        guard !model.files.isEmpty else { return }
        let menu = makeMenu(for: model.files, single: nil)
        menuOpen = true
        defer { menuOpen = false }
        let y = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
        _ = menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: y), in: button)
    }
    private func popUpMenu(for url: URL, event: NSEvent, in source: NSView) {
        guard model.files.contains(url) else { return }
        let menu = makeMenu(for: [url], single: url)
        menuOpen = true
        defer { menuOpen = false }
        NSMenu.popUpContextMenu(menu, with: event, for: source)
    }
    /// The actions menu (all files) or one file's context menu.
    private func makeMenu(for urls: [URL], single: URL?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let airDrop: NSSharingService? = NSSharingService(named: .sendViaAirDrop)
        let mail: NSSharingService? = NSSharingService(named: .composeEmail)
        let enabled = DropShelf.enabledActions(count: urls.count,
                                               canAirDrop: airDrop?.canPerform(withItems: urls) ?? false,
                                               canMail: mail?.canPerform(withItems: urls) ?? false)
        func add(_ title: String, _ action: DropShelfAction, _ handler: @escaping () -> Void) {
            let item = DropShelfMenuItem(title, handler: handler)
            item.isEnabled = enabled.contains(action)
            menu.addItem(item)
        }
        if let single {
            menu.addItem(openWithItem(for: single, enabled: enabled.contains(.openWith)))
            menu.addItem(.separator())
        }
        add(L("Show in Finder"), .showInFinder) { [weak self] in self?.revealInFinder(urls) }
        add(L("Quick Look"), .quickLook) { [weak self] in self?.showQuickLook(urls) }
        add(L("AirDrop"), .airDrop) { [weak self] in self?.share(airDrop, urls) }
        add(L("Mail"), .mail) { [weak self] in self?.share(mail, urls) }
        if let single {
            menu.addItem(.separator())
            add(L("Remove from shelf"), .remove) { [weak self] in self?.remove(single) }
        }
        return menu
    }
    /// Open With ▸ the applications that can open the file, default first.
    private func openWithItem(for url: URL, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        let apps = DropShelf.orderedApplications(NSWorkspace.shared.urlsForApplications(toOpen: url), preferred: preferred)
        for (index, app) in apps.prefix(40).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let title = index == 0 && preferred != nil ? String(format: L("%@ (default)"), name) : name
            let entry = DropShelfMenuItem(title) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
            if index == 0, preferred != nil, apps.count > 1 { submenu.addItem(.separator()) }
        }
        item.submenu = submenu
        item.isEnabled = enabled && !apps.isEmpty
        return item
    }
    private func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    /// The shelf panel never becomes key, so Quick Look runs as in the line:
    /// the app comes forward and the preview panel takes the keyboard (Space
    /// or Escape closes it). The app delegate owns the panel's controller;
    /// the shelf's files are set as its contents once it is in front.
    private func showQuickLook(_ urls: [URL]) {
        guard !urls.isEmpty, let preview = QLPreviewPanel.shared() else { return }
        quickLook.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        preview.updateController()
        preview.dataSource = quickLook
        preview.delegate = quickLook
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
        // The controller may take the panel again as it comes forward.
        preview.dataSource = quickLook
        preview.delegate = quickLook
        preview.reloadData()
        preview.currentPreviewItemIndex = 0
    }
    private func share(_ service: NSSharingService?, _ urls: [URL]) {
        guard let service, !urls.isEmpty, service.canPerform(withItems: urls) else { return }
        sharingService = service
        service.delegate = sharing
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }
    func dismiss() {
        generation += 1; model.clear(); view.files = []; view.preview = nil; view.previews = [:]; view.message = ""
        for request in listRequests { QLThumbnailGenerator.shared.cancel(request) }
        listRequests = []
        compactFrame = nil; listFrame = nil; sharingService = nil; menuOpen = false
        view.setMode(.compact)
        panel.orderOut(nil); view.needsDisplay = true
    }
}

/// A plain layer-backed view, not an NSVisualEffectView: custom drawing in a
/// visual-effect view's draw(_:) lands beneath its material layers, which left
/// the box showing only the dark material and the close button.
///
/// Compact view: previews (custom drawn), the close button, the actions
/// button and, for several files, the count pill. Files view: `listView`.
@MainActor final class DropShelfView: NSView, NSDraggingSource {
    enum Mode { case compact, list }
    var onDrop: (([URL]) -> Bool)?
    var onClose: (() -> Void)?
    var dragFiles: (() throws -> [URL])?
    var onDragEnded: (([URL], NSDragOperation) -> Void)?
    var onShowList: (() -> Void)?
    var onBack: (() -> Void)?
    var onActions: ((NSView) -> Void)?
    var onFileMenu: ((URL, NSEvent, NSView) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onRevealAll: (() -> Void)?
    private var draggedFiles: [URL] = []
    var files: [URL] = [] { didSet { filesChanged() } }
    var preview: NSImage?
    /// Card thumbnails by file, when several files are held.
    var previews: [URL: NSImage] = [:]
    var message = ""
    private(set) var mode: Mode = .compact
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
    private let actionsButton = NSButton()
    /// "N items" under the stack; opens the files view.
    let pillButton = NSButton()
    let listView = DropShelfListView(frame: NSRect(origin: .zero, size: DropShelfLayout.compactSize))
    /// Fixed dark surface with explicit light content, independent of the
    /// system appearance, so text and symbols always contrast.
    static let surfaceColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    static let primaryTextColor = NSColor.white
    static let secondaryTextColor = NSColor(white: 1, alpha: 0.72)
    private static let cardColor = NSColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 1)
    private static let pillColor = NSColor(white: 1, alpha: 0.16)
    var shelfDisplay: DropShelfDisplay { DropShelf.display(files: files, message: message) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = DropShelfView.surfaceColor.cgColor
        layer?.cornerRadius = 25; layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel(L("Drop shelf"))
        setAccessibilityHelp(L("Drag to another window"))
        closeButton.title = "×"; closeButton.bezelStyle = .circular
        closeButton.target = self; closeButton.action = #selector(closeShelf)
        closeButton.setAccessibilityLabel(L("Close")); addSubview(closeButton)
        actionsButton.title = ""; actionsButton.bezelStyle = .circular
        actionsButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Actions"))
        actionsButton.imagePosition = .imageOnly
        actionsButton.target = self; actionsButton.action = #selector(showActions(_:))
        actionsButton.setAccessibilityLabel(L("Actions")); addSubview(actionsButton)
        pillButton.isBordered = false
        pillButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        pillButton.imagePosition = .imageTrailing
        pillButton.contentTintColor = DropShelfView.primaryTextColor
        pillButton.target = self; pillButton.action = #selector(openList)
        addSubview(pillButton)
        listView.shelf = self
        listView.backButton.target = self; listView.backButton.action = #selector(goBack)
        listView.finderButton.target = self; listView.finderButton.action = #selector(revealAll)
        addSubview(listView)
        filesChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }
    @objc private func closeShelf() { onClose?() }
    @objc private func showActions(_ sender: NSButton) { onActions?(sender) }
    @objc private func openList() { onShowList?() }
    @objc private func goBack() { onBack?() }
    @objc private func revealAll() { onRevealAll?() }
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        down = nil
        if mode == .list { listView.setFiles(files, previews: previews) }
        updateControls()
    }
    private func filesChanged() {
        if let title = DropShelf.pillTitle(count: files.count) {
            pillButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: DropShelfView.primaryTextColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            pillButton.setAccessibilityLabel(title)
        }
        if mode == .list { listView.setFiles(files, previews: previews) }
        updateControls()
    }
    private func updateControls() {
        closeButton.isHidden = mode == .list
        actionsButton.isHidden = mode == .list || files.isEmpty
        pillButton.isHidden = mode == .list || DropShelf.pillTitle(count: files.count) == nil
        listView.isHidden = mode != .list
        relayout()
        needsDisplay = true
    }
    private func relayout() {
        let size = bounds.size
        closeButton.frame = NSRect(x: 9, y: size.height - 37, width: 28, height: 28)
        actionsButton.frame = NSRect(x: size.width - 37, y: size.height - 37, width: 28, height: 28)
        pillButton.sizeToFit()
        let width = max(0, min(pillButton.frame.width + 20, size.width - 40))
        pillButton.frame = NSRect(x: ((size.width - width) / 2).rounded(), y: 49, width: width, height: 24)
        listView.frame = bounds
        listView.layoutContents()
    }
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
        // The files view is built from subviews drawn over this surface.
        guard mode == .compact else { return }
        if !pillButton.isHidden {
            DropShelfView.pillColor.setFill()
            NSBezierPath(roundedRect: pillButton.frame, xRadius: pillButton.frame.height / 2, yRadius: pillButton.frame.height / 2).fill()
        }
        let state = shelfDisplay
        // Symbols are template images: drawn directly they come out black on
        // the dark surface. Tint them; real previews are drawn as they are.
        let area = DropShelf.previewArea(in: bounds)
        let shown = DropShelf.stackFiles(files)
        if shown.count > 1 {
            // Several files: a fanned stack, back to front, so every file
            // behind the front one still shows a strip.
            for (file, card) in zip(shown, DropShelf.stackLayout(count: shown.count, in: area)) {
                drawCard(card, image: previews[file], symbol: file.hasDirectoryPath ? "folder" : "doc")
            }
        } else {
            let box = DropShelf.stackLayout(count: 1, in: area).first?.frame ?? NSRect(x: bounds.midX - 50, y: 80, width: 100, height: 100)
            if let preview, preview.size.width > 0, preview.size.height > 0 {
                DropShelfView.drawFrameless(preview, in: DropShelf.framelessRect(imageSize: preview.size, in: box), radius: 8)
            } else {
                DropShelfView.drawSymbol(state.symbol, in: box, color: DropShelfView.primaryTextColor)
            }
        }
        func label(_ text: String, y: Double, size: Double, weight: NSFont.Weight, color: NSColor) {
            guard !text.isEmpty else { return }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(in: NSRect(x: 12, y: y, width: bounds.width - 24, height: 22), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        }
        // Several files show the count pill instead of a title line.
        if files.count <= 1 {
            label(state.title, y: 53, size: 13, weight: .semibold, color: DropShelfView.primaryTextColor)
            label(state.subtitle, y: 31, size: 11, weight: .regular, color: DropShelfView.secondaryTextColor)
        }
        label(state.detail, y: 10, size: 10, weight: .medium, color: state.isWarning ? .systemOrange : DropShelfView.secondaryTextColor)
    }
    /// One card of the stack, rotated about its centre. With a thumbnail the
    /// thumbnail itself is the card (frameless); until one arrives, or if it
    /// failed, a neutral placeholder card with the tinted symbol.
    private func drawCard(_ card: DropShelfCard, image: NSImage?, symbol: String) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: card.center.x, yBy: card.center.y)
        transform.rotate(byDegrees: card.rotation)
        transform.concat()
        let rect = NSRect(x: -card.size.width / 2, y: -card.size.height / 2, width: card.size.width, height: card.size.height)
        if let image, image.size.width > 0, image.size.height > 0 {
            DropShelfView.drawFrameless(image, in: DropShelf.framelessRect(imageSize: image.size, in: rect), radius: 6)
            return
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        context.saveGraphicsState()
        DropShelfView.cardShadow().set()
        DropShelfView.cardColor.setFill()
        path.fill()
        context.restoreGraphicsState()
        context.saveGraphicsState()
        path.addClip()
        DropShelfView.drawSymbol(symbol, in: rect, color: DropShelfView.primaryTextColor)
        context.restoreGraphicsState()
    }
    private static func cardShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }
    /// The image at `rect`, clipped to small rounded corners, with a soft
    /// shadow and nothing behind it. The shadow follows the image's own
    /// shape: it is applied to a transparency layer holding the clipped image.
    static func drawFrameless(_ image: NSImage, in rect: NSRect, radius: CGFloat) {
        guard let context = NSGraphicsContext.current, rect.width > 0, rect.height > 0 else { return }
        let corner = min(radius, rect.width / 4, rect.height / 4)
        context.saveGraphicsState()
        cardShadow().set()
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGraphicsState()
        context.cgContext.endTransparencyLayer()
        context.restoreGraphicsState()
    }
    /// Draws a template symbol in `color`: the glyph is painted into its own
    /// transparency layer, then recoloured only where the glyph has pixels.
    static func drawSymbol(_ name: String, in box: NSRect, color: NSColor, inset: CGFloat = 10) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)),
              let context = NSGraphicsContext.current else { return }
        let rect = DropShelf.aspectFit(symbol.size, in: box.insetBy(dx: inset, dy: inset))
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
        else if mode == .compact { down = point }
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
                let image = previews[url] ?? (index == 0 ? preview : nil)
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
    /// One file dragged out of the files view. The shelf view is the source,
    /// so the drag follows the same copy/move rules and after-drag
    /// bookkeeping as the whole-shelf drag, and cannot drop back onto it.
    func beginFileDrag(_ url: URL, image: NSImage?, event: NSEvent, from row: NSView, at point: NSPoint) {
        guard (try? url.checkResourceIsReachable()) == true else {
            // Gone from its stored place: prune it once this event is over.
            DispatchQueue.main.async { [weak self] in self?.onDragEnded?([], []) }
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                              contents: image ?? NSImage(systemSymbolName: url.hasDirectoryPath ? "folder" : "doc", accessibilityDescription: nil))
        draggedFiles = [url]
        let session = row.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
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

/// A label that lets clicks through to the box (so its header still moves it).
@MainActor final class DropShelfLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBordered = false; isBezeled = false; drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Rows from the top.
@MainActor final class DropShelfListDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The files view: back button and "N items · size" header, a scrolling
/// list of every stored file, and Show in Finder at the bottom.
@MainActor final class DropShelfListView: NSView {
    weak var shelf: DropShelfView?
    let backButton = NSButton()
    let finderButton = NSButton(title: L("Show in Finder"), target: nil, action: nil)
    private let titleLabel = DropShelfLabel(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let document = DropShelfListDocument(frame: .zero)
    private(set) var rows: [DropShelfFileRow] = []
    private var sizes: [URL: Int64] = [:]
    /// The header text.
    var headerTitle: String { titleLabel.stringValue }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backButton.title = ""; backButton.bezelStyle = .circular
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Back"))
        backButton.imagePosition = .imageOnly
        backButton.setAccessibilityLabel(L("Back"))
        addSubview(backButton)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DropShelfView.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        addSubview(scrollView)
        addSubview(finderButton)
        layoutContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Blank areas belong to the box underneath (header drag, drops).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    func layoutContents() {
        let size = bounds.size
        backButton.frame = NSRect(x: 9, y: size.height - 37, width: 28, height: 28)
        titleLabel.frame = NSRect(x: 44, y: size.height - 33, width: max(0, size.width - 56), height: 18)
        finderButton.sizeToFit()
        let buttonWidth = max(0, min(finderButton.frame.width + 16, size.width - 24))
        finderButton.frame = NSRect(x: ((size.width - buttonWidth) / 2).rounded(), y: 10, width: buttonWidth, height: 28)
        scrollView.frame = NSRect(x: 12, y: 46, width: max(0, size.width - 24), height: max(0, size.height - 92))
        layoutRows()
    }
    private func layoutRows() {
        let width = scrollView.contentSize.width, rowHeight = DropShelfLayout.listRowHeight
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(rows.count) * rowHeight, scrollView.contentSize.height))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
        }
    }
    /// One row per stored file, in stored order. Rows for files still held
    /// keep their thumbnail and size.
    func setFiles(_ files: [URL], previews: [URL: NSImage]) {
        var existing: [URL: DropShelfFileRow] = [:]
        for row in rows { existing[row.url] = row }
        let next = files.map { url -> DropShelfFileRow in
            if let row = existing[url] { return row }
            let row = DropShelfFileRow(url: url)
            row.image = previews[url]
            return row
        }
        for row in rows where !next.contains(where: { $0 === row }) { row.removeFromSuperview() }
        rows = next
        for row in rows {
            row.shelf = shelf
            if row.superview == nil { document.addSubview(row) }
            if row.image == nil, let image = previews[row.url] { row.image = image }
            row.sizeText = sizes[row.url].map { DropShelfListView.sizeText($0) } ?? ""
        }
        updateTitle()
        layoutRows()
    }
    func setImage(_ image: NSImage, for url: URL) {
        if let row = rows.first(where: { $0.url == url }) { row.image = image }
    }
    func setSizes(_ values: [Int64?], for files: [URL]) {
        for (url, value) in zip(files, values) {
            if let value { sizes[url] = value }
        }
        for row in rows { row.sizeText = sizes[row.url].map { DropShelfListView.sizeText($0) } ?? "" }
        updateTitle()
    }
    private func updateTitle() {
        titleLabel.stringValue = DropShelf.listTitle(count: rows.count, totalBytes: DropShelf.totalBytes(rows.map { sizes[$0.url] }))
    }
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One file in the files view: its thumbnail (or symbol), name and size.
/// Drag it out, double-click to open, right-click (or Control-click) for
/// its menu.
@MainActor final class DropShelfFileRow: NSView {
    let url: URL
    weak var shelf: DropShelfView?
    var image: NSImage? { didSet { needsDisplay = true } }
    var sizeText = "" { didSet { needsDisplay = true } }
    private var down: NSPoint?
    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: DropShelfLayout.listRowHeight))
        let name = DropShelfFileRow.name(of: url)
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func name(of url: URL) -> String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { down = nil; shelf?.onFileMenu?(url, event, self); return }
        if event.clickCount == 2 { down = nil; shelf?.onOpenFile?(url); return }
        down = convert(event.locationInWindow, from: nil)
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        down = nil
        shelf?.beginFileDrag(url, image: image, event: event, from: self, at: point)
    }
    override func rightMouseDown(with event: NSEvent) {
        down = nil
        shelf?.onFileMenu?(url, event, self)
    }
    override func draw(_ dirtyRect: NSRect) {
        let icon = NSRect(x: 6, y: ((bounds.height - 30) / 2).rounded(), width: 30, height: 30)
        if let image, image.size.width > 0, image.size.height > 0 {
            let rect = DropShelf.framelessRect(imageSize: image.size, in: icon)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            DropShelfView.drawSymbol(url.hasDirectoryPath ? "folder" : "doc", in: icon, color: DropShelfView.primaryTextColor, inset: 3)
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        let x: CGFloat = 44, width = max(0, bounds.width - 50)
        (DropShelfFileRow.name(of: url) as NSString).draw(in: NSRect(x: x, y: bounds.midY - 1, width: width, height: 17), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: DropShelfView.primaryTextColor, .paragraphStyle: style])
        (sizeText as NSString).draw(in: NSRect(x: x, y: bounds.midY - 16, width: width, height: 15), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: DropShelfView.secondaryTextColor, .paragraphStyle: style])
    }
}
