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
    func testPlacementAvoidsWindowsAndPointer() {
        let area = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let obstacle = NSRect(x: 0, y: 0, width: 900, height: 800)
        let pointer = NSPoint(x: 1160, y: 50)
        let rect = DropShelf.placement(area: area, pointer: pointer, obstacles: [obstacle])
        XCTAssertTrue(area.contains(rect)); XCTAssertFalse(rect.intersects(obstacle)); XCTAssertFalse(rect.contains(pointer))
        let small = NSRect(x: -400, y: 100, width: 180, height: 200)
        XCTAssertEqual(DropShelf.placement(area: small, pointer: .zero, obstacles: [small]), small)
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
