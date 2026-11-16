import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor private final class DeferredShelfFile: NSObject {
    let file: URL
    var requests = 0
    init(file: URL) { self.file = file }
    @objc func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
        sender.setString(file.absoluteString, forType: type)
    }
}

/// Native pasteboard payload and operation metadata, with no user clipboard or
/// posted mouse events. Tests drive the real destination's entire handshake.
@MainActor private final class ShelfDropInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint(x: 108, y: 114)
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(board: NSPasteboard) { draggingPasteboard = board; super.init() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor final class DropShelfTests: HistoryTestCase {
    func testNonactivatingShelfAcceptsTheFirstMouseDown() {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }
    func testFileDropCompletesAppKitDestinationHandshake() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Synthetic document.txt"), folder = root.appendingPathComponent("Synthetic folder", isDirectory: true)
        try Data("original".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let board = NSPasteboard(name: .init("drop-shelf-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([file as NSURL, folder as NSURL]))
        let info = ShelfDropInfo(board: board)
        let controller = DropShelfController(); defer { controller.stop() }
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        let panel = DropShelfPanel(content: view)
        defer { panel.close() }
        info.draggingDestinationWindow = panel
        var drops = 0
        view.onDrop = { urls in drops += 1; return controller.accept(urls) }
        // Exercise the same surface AppKit hits in the center of the window.
        XCTAssertTrue(view.hitTest(NSPoint(x: 108, y: 114)) === view)
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertEqual(view.draggingUpdated(info), .copy)
        XCTAssertTrue(controller.model.files.isEmpty, "Hover must not import the payload")
        let prepared = view.prepareForDragOperation(info)
        XCTAssertTrue(prepared, "A valid drop must pass AppKit's pre-drop approval, not bounce back to Finder")
        if prepared { XCTAssertTrue(view.performDragOperation(info)) }
        view.concludeDragOperation(info)
        XCTAssertEqual(drops, 1)
        XCTAssertEqual(try controller.model.dragFiles(), [file, folder])
        controller.dismiss()
        // AppKit may route the drag to the window when a nonactivating panel
        // appears during an external drag. That path must perform the same drop.
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.draggingEntered(info), .copy)
        XCTAssertEqual(panel.draggingUpdated(info), .copy)
        XCTAssertTrue(panel.prepareForDragOperation(info))
        XCTAssertTrue(panel.performDragOperation(info))
        panel.concludeDragOperation(info)
        XCTAssertEqual(drops, 2)
        XCTAssertEqual(try controller.model.dragFiles(), [file, folder])
        controller.dismiss()
        XCTAssertEqual(try String(contentsOf: file), "original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testBlankDropSurfaceIsOpaqueForWindowServerHitTesting() throws {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 216, pixelsHigh: 228, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill(); view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        // Empty areas away from the icon, text and buttons must still have
        // opaque pixels; behind-window material or a faint fill is insufficient
        // when a drag approaches through the blank area without crossing icons.
        for point in [(20, 70), (195, 70), (20, 150), (195, 150)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1))
            XCTAssertGreaterThan(color.alphaComponent, 0.99)
        }
    }

    func testDropHandshakeRejectsChangedPayloadAndUnsafeOperations() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("original".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard(name: .init("drop-shelf-reject-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        let info = ShelfDropInfo(board: board), view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        var drops = 0
        view.onDrop = { _ in drops += 1; return true }
        XCTAssertEqual(view.draggingEntered(info), .copy)
        info.draggingSourceOperationMask = .move
        XCTAssertEqual(view.draggingUpdated(info), [])
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        info.draggingSourceOperationMask = .copy
        info.draggingSource = view
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        info.draggingSource = nil
        XCTAssertTrue(view.prepareForDragOperation(info))
        board.clearContents(); board.setString("https://example.com/", forType: .string)
        XCTAssertFalse(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertEqual(drops, 0, "Rejected drops must not reach the file store")
        XCTAssertEqual(try String(contentsOf: file), "original")
    }

    func testAdvertisedFileTypeCanHoverBeforeFileDataIsAvailable() {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("drop-shelf-delayed-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        // An advertised type is sufficient for negotiation. Missing/invalid
        // file data still must never be imported when the mouse is released.
        board.declareTypes([.fileURL], owner: nil)
        let info = ShelfDropInfo(board: board)
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        var drops = 0
        view.onDrop = { _ in drops += 1; return true }
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertEqual(view.draggingUpdated(info), .copy)
        XCTAssertTrue(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertEqual(drops, 0)
    }

    func testDeferredFinderFileIsReadOnlyWhenDropped() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("original".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let owner = DeferredShelfFile(file: file)
        let board = NSPasteboard(name: .init("drop-shelf-provider-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.fileURL], owner: owner)
        let info = ShelfDropInfo(board: board)
        let controller = DropShelfController(); defer { controller.stop() }
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        view.onDrop = { controller.accept($0) }
        XCTAssertEqual(view.draggingEntered(info), .copy)
        XCTAssertEqual(view.draggingUpdated(info), .copy)
        XCTAssertTrue(view.prepareForDragOperation(info))
        XCTAssertEqual(owner.requests, 0, "Negotiation must not request deferred file data")
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertGreaterThan(owner.requests, 0)
        XCTAssertEqual(try controller.model.dragFiles(), [file])
        XCTAssertEqual(try String(contentsOf: file), "original")
    }


    func testSharedDropShelfContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["document.txt", "picture.png"] { try Data("synthetic".utf8).write(to: root.appendingPathComponent(name)) }
        for name in ["Folder", "Sample.app"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: checkout.appendingPathComponent("contracts/shelf-behavior.json"))
        let contract = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(contract["dropShelfCases"] as? [[String: Any]])
        let shelf = DropShelf()
        for step in steps {
            if step["action"] as? String == "clear" { shelf.clear() }
            else { try shelf.add(try XCTUnwrap(step["files"] as? [String]).map { root.appendingPathComponent($0) }) }
            XCTAssertEqual(shelf.files.map(\.lastPathComponent), try XCTUnwrap(step["expected"] as? [String]))
        }
        XCTAssertEqual(try shelf.dragFiles(), [root.appendingPathComponent("Folder")])
        shelf.clear()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("document.txt")), "synthetic")
        let file = root.appendingPathComponent("document.txt")
        try shelf.add([file, file]); XCTAssertEqual(shelf.files.count, 1)
        XCTAssertThrowsError(try shelf.add([root.appendingPathComponent("picture.png"), root.appendingPathComponent("missing")]))
        XCTAssertEqual(shelf.files, [file])
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try shelf.dragFiles())
        XCTAssertThrowsError(try shelf.add([URL(string: "https://example.com/file")!]))
    }
    private func gap(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
    func testPlacementOpensNearPointerAndStaysOnScreen() {
        // A visible frame below a 25 pt menu bar on a secondary screen left of the main one.
        for area in [NSRect(x: 0, y: 70, width: 1440, height: 805), NSRect(x: -1280, y: 0, width: 1280, height: 775)] {
            let pointers = [
                NSPoint(x: area.midX, y: area.midY),
                NSPoint(x: area.minX + 3, y: area.midY), NSPoint(x: area.maxX - 3, y: area.midY),
                NSPoint(x: area.midX, y: area.minY + 3), NSPoint(x: area.midX, y: area.maxY - 3),
                NSPoint(x: area.midX, y: area.maxY + 12), // in the menu bar
                NSPoint(x: area.minX + 2, y: area.minY + 2), NSPoint(x: area.maxX - 2, y: area.maxY - 2),
                NSPoint(x: area.minX + 2, y: area.maxY - 2), NSPoint(x: area.maxX - 2, y: area.minY + 2),
            ]
            for pointer in pointers {
                let rect = DropShelf.placement(area: area, pointer: pointer)
                XCTAssertEqual(rect.size, NSSize(width: 216, height: 228))
                XCTAssertTrue(area.contains(rect), "Outside the visible frame for \(pointer): \(rect)")
                XCTAssertFalse(rect.contains(pointer), "Under the pointer at \(pointer): \(rect)")
                XCTAssertGreaterThan(gap(rect, pointer), 15, "Too close to \(pointer): \(rect)")
                XCTAssertLessThanOrEqual(gap(rect, pointer), 60, "Too far to reach from \(pointer): \(rect)")
                XCTAssertLessThanOrEqual(hypot(rect.midX - pointer.x, rect.midY - pointer.y), 260)
            }
        }
        // With room on both sides the box opens just right of the pointer, centred on it.
        let area = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let middle = DropShelf.placement(area: area, pointer: NSPoint(x: 700, y: 400))
        XCTAssertEqual(middle.minX, 732); XCTAssertEqual(middle.midY, 400, accuracy: 1)
        // At the right edge it opens to the left instead.
        let right = DropShelf.placement(area: area, pointer: NSPoint(x: 1430, y: 400))
        XCTAssertEqual(right.maxX, 1398)
        // A screen smaller than the box still keeps it inside.
        let small = NSRect(x: -400, y: 100, width: 180, height: 200)
        XCTAssertTrue(small.contains(DropShelf.placement(area: small, pointer: NSPoint(x: -300, y: 150))))
    }
    func testDragOutOffersMoveOnlyOutsideTheApp() {
        XCTAssertEqual(DropShelf.dragOperationMask(for: .outsideApplication), [.copy, .move])
        XCTAssertEqual(DropShelf.dragOperationMask(for: .withinApplication), .copy)
    }
    func testStoredItemsAfterMoveCopyAndCancelledDrag() {
        let a = URL(fileURLWithPath: "/synthetic/a.txt"), b = URL(fileURLWithPath: "/synthetic/b", isDirectory: true)
        let c = URL(fileURLWithPath: "/synthetic/c.png")
        let stored = [a, b, c]
        func after(_ dragged: [URL], _ operation: NSDragOperation) -> [URL] {
            DropShelf.filesAfterDrag(stored, dragged: dragged, operation: operation, exists: { _ in true })
        }
        XCTAssertEqual(after(stored, .move), [])
        XCTAssertEqual(after([a, c], .move), [b])
        XCTAssertEqual(after(stored, .copy), stored)
        XCTAssertEqual(after(stored, []), stored, "A cancelled drag keeps everything")
        XCTAssertEqual(after(stored, [.copy, .move]), [], "Any reported move removes the moved items")
    }
    func testEndedDragPrunesFilesThatNoLongerExist() throws {
        let a = URL(fileURLWithPath: "/synthetic/a.txt"), b = URL(fileURLWithPath: "/synthetic/b.txt")
        let operations: [NSDragOperation] = [.copy, [], .move]
        for operation in operations {
            XCTAssertEqual(DropShelf.filesAfterDrag([a, b], dragged: [], operation: operation, exists: { $0 != a }), [b])
        }
        // The controller applies the same rule to real files.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept.txt"), moved = root.appendingPathComponent("moved.txt")
        try Data("synthetic".utf8).write(to: kept); try Data("synthetic".utf8).write(to: moved)
        let controller = DropShelfController(); defer { controller.stop() }
        XCTAssertTrue(controller.accept([kept, moved]))
        controller.dragEnded([kept, moved], operation: .copy)
        XCTAssertEqual(controller.model.files, [kept, moved])
        try FileManager.default.removeItem(at: moved)
        controller.dragEnded([kept, moved], operation: [])
        XCTAssertEqual(controller.model.files, [kept])
        controller.dragEnded([kept], operation: .move)
        XCTAssertTrue(controller.model.files.isEmpty, "Moved items leave the box")
        XCTAssertEqual(try String(contentsOf: kept), "synthetic")
    }
    func testDisplayShowsHintNameOrCountWithoutFileAccess() {
        // Synthetic paths that do not exist: the display must not touch disk.
        let empty = DropShelf.display(files: [], message: "")
        XCTAssertEqual(empty.title, L("Drop files here"))
        XCTAssertFalse(empty.title.isEmpty)
        XCTAssertEqual(empty.symbol, "tray.and.arrow.down")
        XCTAssertFalse(empty.isWarning)
        let file = URL(fileURLWithPath: "/synthetic/Quarterly report.pdf")
        let folder = URL(fileURLWithPath: "/synthetic/Photos", isDirectory: true)
        let one = DropShelf.display(files: [file], message: "")
        XCTAssertEqual(one.title, "Quarterly report.pdf")
        XCTAssertEqual(one.symbol, "doc")
        XCTAssertEqual(one.subtitle, L("Drag to another window"))
        XCTAssertEqual(one.detail, "")
        XCTAssertEqual(DropShelf.display(files: [folder], message: "").title, "Photos")
        XCTAssertEqual(DropShelf.display(files: [folder], message: "").symbol, "folder")
        let several = DropShelf.display(files: [file, folder, URL(fileURLWithPath: "/synthetic/c.png")], message: "")
        XCTAssertEqual(several.title, String(format: L("%d items"), 3))
        XCTAssertTrue(several.title.contains("3"))
        XCTAssertEqual(several.symbol, "doc.on.doc")
        let warned = DropShelf.display(files: [], message: L("A dropped file is no longer available."))
        XCTAssertTrue(warned.isWarning)
        XCTAssertEqual(warned.detail, L("A dropped file is no longer available."))
        XCTAssertEqual(warned.title, L("Drop files here"), "A message never replaces the hint")
    }
    func testPreviewKeepsItsProportionsInsideTheIconBox() {
        let box = NSRect(x: 58, y: 80, width: 100, height: 100)
        let wide = DropShelf.aspectFit(NSSize(width: 200, height: 100), in: box)
        XCTAssertEqual(wide.width, 100, accuracy: 0.001); XCTAssertEqual(wide.height, 50, accuracy: 0.001)
        XCTAssertEqual(wide.midX, box.midX, accuracy: 0.001); XCTAssertEqual(wide.midY, box.midY, accuracy: 0.001)
        let tall = DropShelf.aspectFit(NSSize(width: 10, height: 40), in: box)
        XCTAssertEqual(tall.height, 100, accuracy: 0.001); XCTAssertEqual(tall.width, 25, accuracy: 0.001)
        XCTAssertEqual(DropShelf.aspectFit(.zero, in: box), box)
    }
    private func brightPixels(_ view: DropShelfView) throws -> Int {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 216, pixelsHigh: 228, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill(); view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for x in 0..<216 {
            for y in 0..<228 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.9, color.redComponent > 0.75, color.greenComponent > 0.75, color.blueComponent > 0.75 { count += 1 }
            }
        }
        return count
    }
    func testShelfDrawsContrastingContentInEveryState() throws {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        // The surface is dark; the hint, symbol, name and count are light.
        XCTAssertGreaterThan(try brightPixels(view), 100, "The empty box must show a visible hint")
        view.files = [URL(fileURLWithPath: "/synthetic/Quarterly report.pdf")]
        XCTAssertEqual(view.shelfDisplay.title, "Quarterly report.pdf")
        XCTAssertGreaterThan(try brightPixels(view), 100, "A held file must be visible before any preview arrives")
        view.files.append(URL(fileURLWithPath: "/synthetic/Photos", isDirectory: true))
        XCTAssertEqual(view.shelfDisplay.title, String(format: L("%d items"), 2))
        XCTAssertGreaterThan(try brightPixels(view), 100)
        // An empty or failed preview image never blanks the box.
        view.preview = NSImage(size: .zero)
        XCTAssertGreaterThan(try brightPixels(view), 100)
    }
    func testUnreadableDropShowsAMessageInsteadOfABlankBox() {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("drop-shelf-unreadable-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.fileURL], owner: nil)
        let info = ShelfDropInfo(board: board)
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        var drops = 0
        view.onDrop = { _ in drops += 1; return true }
        XCTAssertEqual(view.shelfDisplay.detail, "")
        XCTAssertTrue(view.prepareForDragOperation(info))
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertEqual(drops, 0)
        XCTAssertEqual(view.shelfDisplay.detail, L("A dropped file is no longer available."))
        XCTAssertTrue(view.shelfDisplay.isWarning)
        // A drop the controller refuses also leaves a visible message.
        let refusing = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        refusing.onDrop = { _ in false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        XCTAssertFalse(refusing.performDragOperation(info))
        XCTAssertTrue(refusing.shelfDisplay.isWarning)
    }
    func testFileReferenceURLIsStoredByPathAndName() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " named.txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())
        let shelf = DropShelf()
        try shelf.add([reference])
        XCTAssertEqual(shelf.files.map(\.lastPathComponent), [file.lastPathComponent])
        XCTAssertEqual(DropShelf.display(files: shelf.files, message: "").title, file.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: file), "synthetic")
    }
    func testControllerAcceptsFilesAndClosePreservesOriginals() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = DropShelfController()
        XCTAssertTrue(controller.accept([file]))
        XCTAssertEqual(try controller.model.dragFiles(), [file])
        controller.dismiss()
        XCTAssertTrue(controller.model.files.isEmpty)
        XCTAssertEqual(try String(contentsOf: file), "synthetic")
        controller.stop()
    }
}
