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
        // The old "Drag to another window" line is gone; the empty box keeps its caption.
        XCTAssertEqual(one.subtitle, "")
        XCTAssertEqual(empty.subtitle, L("Drop shelf"))
        XCTAssertEqual(one.detail, "")
        XCTAssertEqual(DropShelf.display(files: [folder], message: "").title, "Photos")
        XCTAssertEqual(DropShelf.display(files: [folder], message: "").symbol, "folder")
        let several = DropShelf.display(files: [file, folder, URL(fileURLWithPath: "/synthetic/c.png")], message: "")
        XCTAssertEqual(several.title, String(format: L("%d items"), 3))
        XCTAssertTrue(several.title.contains("3"))
        XCTAssertEqual(several.symbol, "doc.on.doc")
        XCTAssertEqual(several.subtitle, "")
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
    /// The view drawn into a 1x bitmap whose rows count from the top.
    private func render(_ view: DropShelfView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 216, pixelsHigh: 228, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill(); view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    /// Light pixels inside `rect`, given in the view's unflipped coordinates.
    private func brightPixels(_ view: DropShelfView, in rect: NSRect) throws -> Int {
        let bitmap = try render(view)
        var count = 0
        for x in Int(rect.minX.rounded())..<Int(rect.maxX.rounded()) {
            for viewY in Int(rect.minY.rounded())..<Int(rect.maxY.rounded()) {
                guard let color = bitmap.colorAt(x: x, y: 227 - viewY)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.9, color.redComponent > 0.75, color.greenComponent > 0.75, color.blueComponent > 0.75 { count += 1 }
            }
        }
        return count
    }
    /// Whether `point` lies inside the rotated card, at least `inset` from its
    /// edges (a negative inset grows the card).
    private func cardContains(_ card: DropShelfCard, _ point: NSPoint, inset: CGFloat) -> Bool {
        let radians = Double(card.rotation) * Double.pi / 180
        let dx = Double(point.x - card.center.x), dy = Double(point.y - card.center.y)
        let x = dx * cos(radians) + dy * sin(radians), y = -dx * sin(radians) + dy * cos(radians)
        return abs(x) < Double(card.size.width / 2 - inset) && abs(y) < Double(card.size.height / 2 - inset)
    }
    /// For each card of the drawn stack, back to front: the pixels of the card
    /// that no card in front covers (4 pt in from its own edge and 10 pt clear
    /// of every card in front, so borders, antialiasing and the front cards'
    /// shadows never count), and how many of those are drawn lighter than the
    /// box's surface. Without the card they would show the bare surface.
    private func uncoveredCardPixels(_ view: DropShelfView) throws -> [(region: Int, lighter: Int)] {
        let bitmap = try render(view)
        let cards = DropShelf.stackLayout(count: DropShelf.stackFiles(view.files).count, in: DropShelf.previewArea(in: view.bounds))
        // Bare surface, left of the preview area and below the close button.
        let surface = try XCTUnwrap(bitmap.colorAt(x: 20, y: 227 - 120)?.usingColorSpace(.deviceRGB))
        var result: [(region: Int, lighter: Int)] = []
        for (index, card) in cards.enumerated() {
            let box = card.boundingBox
            var region = 0, lighter = 0
            for x in Int(box.minX.rounded(.down))..<Int(box.maxX.rounded(.up)) {
                for y in Int(box.minY.rounded(.down))..<Int(box.maxY.rounded(.up)) {
                    let point = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    guard cardContains(card, point, inset: 4),
                          !cards[(index + 1)...].contains(where: { cardContains($0, point, inset: -10) }) else { continue }
                    region += 1
                    guard let color = bitmap.colorAt(x: x, y: 227 - y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.9, color.redComponent > surface.redComponent + 0.05,
                       color.greenComponent > surface.greenComponent + 0.05, color.blueComponent > surface.blueComponent + 0.05 { lighter += 1 }
                }
            }
            result.append((region: region, lighter: lighter))
        }
        return result
    }
    func testStackLayoutFansUpToFourCardsInsideThePreviewArea() {
        let bounds = NSRect(x: 0, y: 0, width: 216, height: 228)
        let area = DropShelf.previewArea(in: bounds)
        // Clear of the title (y 53–75), the close button (x 9–37, y ≥ 191) and the view.
        XCTAssertGreaterThan(area.minY, 75)
        XCTAssertLessThanOrEqual(area.maxY, 191)
        XCTAssertGreaterThan(area.minX, 37)
        XCTAssertLessThanOrEqual(area.maxX, bounds.maxX - 12)
        XCTAssertTrue(DropShelf.stackLayout(count: 0, in: area).isEmpty)
        // One file keeps today's single upright 100 pt preview.
        let one = DropShelf.stackLayout(count: 1, in: area)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.first?.frame, NSRect(x: bounds.midX - 50, y: 80, width: 100, height: 100))
        XCTAssertEqual(one.first?.rotation, 0)
        for count in 2...9 {
            let cards = DropShelf.stackLayout(count: count, in: area)
            XCTAssertEqual(cards.count, min(count, 4))
            for card in cards {
                let box = card.boundingBox
                XCTAssertGreaterThan(box.minX, area.minX - 0.01, "Card leaves the preview area for \(count)")
                XCTAssertLessThan(box.maxX, area.maxX + 0.01, "Card leaves the preview area for \(count)")
                XCTAssertGreaterThan(box.minY, area.minY - 0.01, "Card leaves the preview area for \(count)")
                XCTAssertLessThan(box.maxY, area.maxY + 0.01, "Card leaves the preview area for \(count)")
                XCTAssertLessThan(card.size.width, 100, "Stacked cards are smaller than the single preview")
                XCTAssertGreaterThan(card.size.width, 50)
            }
            for i in cards.indices {
                // Rotations and positions mirror about the stack centre.
                let mirror = cards[cards.count - 1 - i]
                XCTAssertEqual(cards[i].rotation, -mirror.rotation, accuracy: 0.0001)
                XCTAssertEqual(cards[i].center.x - area.midX, area.midX - mirror.center.x, accuracy: 0.0001)
                XCTAssertLessThanOrEqual(abs(cards[i].rotation), 8)
                if i > 0 {
                    // The front card never hides most of the card behind it.
                    XCTAssertGreaterThan(cards[i].center.x - cards[i - 1].center.x, 0.4 * cards[i].size.width, "Card behind is covered for \(count)")
                }
                for j in cards.indices where j > i {
                    // Each card behind leaves a clear strip on its left.
                    XCTAssertGreaterThan(cards[j].center.x - cards[i].center.x, 15)
                    XCTAssertGreaterThan(cards[j].boundingBox.minX - cards[i].boundingBox.minX, 15)
                    XCTAssertNotEqual(cards[i], cards[j])
                }
            }
            XCTAssertNotEqual(cards.first?.rotation, 0, "The stack is fanned")
        }
        // Portrait and landscape thumbnails each fit inside their card.
        let card = DropShelf.stackLayout(count: 3, in: area)[0].frame
        for size in [NSSize(width: 300, height: 900), NSSize(width: 1600, height: 900)] {
            let fitted = DropShelf.aspectFit(size, in: card.insetBy(dx: 4, dy: 4))
            XCTAssertGreaterThan(fitted.minX, card.minX - 0.001); XCTAssertLessThan(fitted.maxX, card.maxX + 0.001)
            XCTAssertGreaterThan(fitted.minY, card.minY - 0.001); XCTAssertLessThan(fitted.maxY, card.maxY + 0.001)
            XCTAssertEqual(fitted.width / fitted.height, size.width / size.height, accuracy: 0.001)
        }
        // The last four added are shown, the most recent in front (last).
        let urls = (1...6).map { URL(fileURLWithPath: "/synthetic/\($0).txt") }
        XCTAssertEqual(DropShelf.stackFiles(urls), Array(urls[2...]))
        XCTAssertEqual(DropShelf.stackFiles(Array(urls[..<2])), Array(urls[..<2]))
    }
    func testSeveralFilesDrawAVisibleStackBeforeAnyThumbnail() throws {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        let area = DropShelf.previewArea(in: view.bounds)
        let files = [URL(fileURLWithPath: "/synthetic/a.txt"), URL(fileURLWithPath: "/synthetic/b.png"),
                     URL(fileURLWithPath: "/synthetic/Photos", isDirectory: true), URL(fileURLWithPath: "/synthetic/d.pdf"),
                     URL(fileURLWithPath: "/synthetic/e.txt")]
        func assertEveryCardShows(_ label: String) throws {
            let cards = try uncoveredCardPixels(view)
            XCTAssertEqual(cards.count, min(view.files.count, 4), label)
            for (index, card) in cards.enumerated() {
                // Geometry: a real strip of every card behind stays uncovered
                // (over 400 px after the margins; the old 72 pt, 4-file layout left
                // under 350, about 28% of each card).
                XCTAssertGreaterThan(card.region, 400, "\(label): card \(index) is hidden")
                // Drawing: that strip shows the card, not the bare surface.
                XCTAssertGreaterThan(card.lighter, card.region * 9 / 10, "\(label): card \(index) is not drawn")
            }
        }
        for count in 2...5 {
            view.files = Array(files[..<count])
            XCTAssertEqual(view.shelfDisplay.title, String(format: L("%d items"), count))
            try assertEveryCardShows("\(count) files")
        }
        // A failed thumbnail for one card never blanks the others.
        view.files = Array(files[..<3])
        view.previews[files[1]] = NSImage(size: .zero)
        try assertEveryCardShows("failed thumbnail")
        // A single file still draws its one large symbol.
        view.files = [files[0]]; view.previews = [:]
        XCTAssertGreaterThan(try brightPixels(view, in: area), 100)
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
    func testPillAndFileListTitles() {
        XCTAssertNil(DropShelf.pillTitle(count: 0))
        XCTAssertNil(DropShelf.pillTitle(count: 1), "One file shows its name, not a pill")
        XCTAssertEqual(DropShelf.pillTitle(count: 2), String(format: L("%d items"), 2))
        XCTAssertEqual(DropShelf.pillTitle(count: 37), String(format: L("%d items"), 37))
        XCTAssertTrue(DropShelf.pillTitle(count: 37)?.contains("37") == true)
        // The header shows the count at once and the total size once every size is read.
        XCTAssertEqual(DropShelf.listTitle(count: 3, totalBytes: nil), String(format: L("%d items"), 3))
        let sized = DropShelf.listTitle(count: 3, totalBytes: 2_500_000)
        XCTAssertTrue(sized.hasPrefix(String(format: L("%d items"), 3)))
        XCTAssertTrue(sized.hasSuffix(ByteCountFormatter.string(fromByteCount: 2_500_000, countStyle: .file)))
        XCTAssertEqual(DropShelf.totalBytes([1_000, 24, 0]), 1_024)
        XCTAssertNil(DropShelf.totalBytes([1_000, nil, 24]), "A partial sum is never shown as the total")
        XCTAssertNil(DropShelf.totalBytes([]))
    }
    func testDiskSizeCountsFilesAndFolderContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data(count: 300).write(to: file)
        try Data(count: 200).write(to: folder.appendingPathComponent("b.bin"))
        try Data(count: 50).write(to: folder.appendingPathComponent("Inner/c.bin"))
        XCTAssertEqual(DropShelf.diskSize(of: file), 300)
        XCTAssertEqual(DropShelf.diskSize(of: folder), 250)
        XCTAssertNil(DropShelf.diskSize(of: root.appendingPathComponent("missing")))
    }
    func testMenuItemsEnabledForEmptyAndNonEmptySelection() {
        XCTAssertTrue(DropShelf.enabledActions(count: 0, canAirDrop: true, canMail: true).isEmpty, "Nothing to act on")
        XCTAssertEqual(DropShelf.enabledActions(count: 1, canAirDrop: true, canMail: true), Set(DropShelfAction.allCases))
        XCTAssertEqual(DropShelf.enabledActions(count: 1, canAirDrop: false, canMail: false), [.openWith, .showInFinder, .quickLook, .remove])
        // The actions menu acts on every file; Open With and Remove belong to one file's menu.
        XCTAssertEqual(DropShelf.enabledActions(count: 4, canAirDrop: true, canMail: false), [.showInFinder, .quickLook, .airDrop])
        XCTAssertEqual(DropShelf.enabledActions(count: 4, canAirDrop: false, canMail: true), [.showInFinder, .quickLook, .mail])
        // Open With: the default application first, each application once.
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
        let other = URL(fileURLWithPath: "/Applications/Other.app", isDirectory: true)
        XCTAssertEqual(DropShelf.orderedApplications([other, preview, other], preferred: preview), [preview, other])
        XCTAssertEqual(DropShelf.orderedApplications([other], preferred: nil), [other])
        XCTAssertTrue(DropShelf.orderedApplications([], preferred: nil).isEmpty)
        // A shelf menu, Quick Look or a share in progress keeps the visible box where it is.
        XCTAssertFalse(DropShelf.monitorPaused(menuOpen: false, quickLookOpen: false, sharing: false, panelVisible: true))
        XCTAssertTrue(DropShelf.monitorPaused(menuOpen: true, quickLookOpen: false, sharing: false, panelVisible: true))
        XCTAssertTrue(DropShelf.monitorPaused(menuOpen: false, quickLookOpen: true, sharing: false, panelVisible: true))
        XCTAssertTrue(DropShelf.monitorPaused(menuOpen: false, quickLookOpen: false, sharing: true, panelVisible: true))
        XCTAssertFalse(DropShelf.monitorPaused(menuOpen: true, quickLookOpen: true, sharing: true, panelVisible: false),
                       "A hidden box still reappears for the next file drag")
    }
    func testRemoveFromShelfTakesOnlyThatEntryAndKeepsTheFile() throws {
        let a = URL(fileURLWithPath: "/synthetic/a.txt"), b = URL(fileURLWithPath: "/synthetic/b", isDirectory: true)
        let c = URL(fileURLWithPath: "/synthetic/c.png")
        XCTAssertEqual(DropShelf.filesRemoving(b, from: [a, b, c]), [a, c])
        XCTAssertEqual(DropShelf.filesRemoving(URL(fileURLWithPath: "/synthetic/other"), from: [a, b, c]), [a, b, c])
        XCTAssertEqual(DropShelf.filesRemoving(a, from: [a]), [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["one.txt", "two.txt", "three.txt"].map { root.appendingPathComponent($0) }
        for file in files { try Data("synthetic".utf8).write(to: file) }
        let controller = DropShelfController(); defer { controller.stop() }
        XCTAssertTrue(controller.accept(files))
        controller.showList()
        XCTAssertTrue(controller.isShowingList)
        controller.remove(files[1])
        XCTAssertEqual(controller.model.files, [files[0], files[2]])
        XCTAssertTrue(controller.isShowingList)
        // Down to one file the list has no pill to return to: back to the compact box.
        controller.remove(files[0])
        XCTAssertEqual(controller.model.files, [files[2]])
        XCTAssertFalse(controller.isShowingList)
        controller.remove(files[2])
        XCTAssertTrue(controller.model.files.isEmpty)
        for file in files { XCTAssertEqual(try String(contentsOf: file), "synthetic", "Remove never touches the file") }
    }
    func testFileListOpensAndReturnsWithEveryFileListed() throws {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        XCTAssertTrue(view.pillButton.isHidden, "No pill for an empty box")
        view.files = [URL(fileURLWithPath: "/synthetic/one.txt")]
        XCTAssertTrue(view.pillButton.isHidden, "No pill for one file")
        let files = (1...7).map { URL(fileURLWithPath: "/synthetic/file \($0).txt") }
        view.files = files
        XCTAssertFalse(view.pillButton.isHidden)
        XCTAssertEqual(view.pillButton.attributedTitle.string, String(format: L("%d items"), 7))
        // The pill sits centred under the stack, clear of the preview area.
        XCTAssertEqual(view.pillButton.frame.midX, view.bounds.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(view.pillButton.frame.maxY, DropShelf.previewArea(in: view.bounds).minY)
        view.setMode(.list)
        XCTAssertEqual(view.mode, .list)
        XCTAssertTrue(view.pillButton.isHidden)
        XCTAssertFalse(view.listView.isHidden)
        XCTAssertEqual(view.listView.rows.map(\.url), files)
        XCTAssertEqual(view.listView.headerTitle, String(format: L("%d items"), 7))
        view.listView.setSizes(Array(repeating: Optional(Int64(1_000)), count: 7), for: files)
        XCTAssertEqual(view.listView.headerTitle, DropShelf.listTitle(count: 7, totalBytes: 7_000))
        // A drop or a drag-out changes the list in place; sizes already read stay.
        view.files = Array(files[2...])
        XCTAssertEqual(view.listView.rows.map(\.url), Array(files[2...]))
        XCTAssertEqual(view.listView.headerTitle, DropShelf.listTitle(count: 5, totalBytes: 5_000))
        view.setMode(.compact)
        XCTAssertTrue(view.listView.isHidden)
        XCTAssertFalse(view.pillButton.isHidden)
    }
    func testFileListFrameStaysOnScreenAndAnchoredToTheBox() {
        let size = DropShelfLayout.listSize
        for area in [NSRect(x: 0, y: 70, width: 1440, height: 805), NSRect(x: -1280, y: 0, width: 1280, height: 775)] {
            let inside = area.insetBy(dx: 8, dy: 8)
            // Compact boxes near every edge and corner (their top-left corners).
            let anchors = [
                NSPoint(x: area.midX, y: area.midY),
                NSPoint(x: area.minX + 8, y: area.midY), NSPoint(x: area.maxX - 224, y: area.midY),
                NSPoint(x: area.midX, y: area.minY + 236), NSPoint(x: area.midX, y: area.maxY - 8),
                NSPoint(x: area.minX + 8, y: area.maxY - 8), NSPoint(x: area.maxX - 224, y: area.minY + 236),
                NSPoint(x: area.maxX + 50, y: area.maxY + 50), NSPoint(x: area.minX - 50, y: area.minY - 50),
            ]
            for anchor in anchors {
                let frame = DropShelf.panelFrame(size: size, topLeft: anchor, in: area)
                XCTAssertEqual(frame.size, size)
                XCTAssertTrue(inside.contains(frame), "Outside the visible frame for \(anchor): \(frame)")
                // It moves only as far as the edge requires.
                let wantedX = min(max(anchor.x, inside.minX), inside.maxX - size.width)
                let wantedTop = min(max(anchor.y, inside.minY + size.height), inside.maxY)
                XCTAssertEqual(frame.minX, wantedX.rounded(), accuracy: 0.5)
                XCTAssertEqual(frame.maxY, wantedTop.rounded(), accuracy: 0.5)
            }
            // With room the top-left corner stays exactly where the box was.
            let middle = DropShelf.panelFrame(size: size, topLeft: NSPoint(x: area.midX, y: area.midY), in: area)
            XCTAssertEqual(middle.minX, area.midX.rounded(), accuracy: 0.5)
            XCTAssertEqual(middle.maxY, area.midY.rounded(), accuracy: 0.5)
            // Back to the compact size at the box's old place.
            let compact = DropShelf.panelFrame(size: DropShelfLayout.compactSize, topLeft: NSPoint(x: area.midX, y: area.midY), in: area)
            XCTAssertEqual(compact.size, DropShelfLayout.compactSize)
        }
        // A screen smaller than the list still keeps it inside.
        let small = NSRect(x: -400, y: 100, width: 300, height: 240)
        let shrunk = DropShelf.panelFrame(size: size, topLeft: NSPoint(x: -300, y: 300), in: small)
        XCTAssertTrue(small.contains(shrunk))
        XCTAssertLessThan(shrunk.width, size.width)
    }
    func testFramelessPreviewKeepsTheImageProportionsInsideItsSlot() {
        let slot = NSRect(x: 58, y: 80, width: 100, height: 100)
        let wide = DropShelf.framelessRect(imageSize: NSSize(width: 1600, height: 900), in: slot)
        XCTAssertEqual(wide.width, 100, accuracy: 0.001); XCTAssertEqual(wide.height, 56.25, accuracy: 0.001)
        XCTAssertEqual(wide.midX, slot.midX, accuracy: 0.001); XCTAssertEqual(wide.midY, slot.midY, accuracy: 0.001)
        let tall = DropShelf.framelessRect(imageSize: NSSize(width: 300, height: 900), in: slot)
        XCTAssertEqual(tall.height, 100, accuracy: 0.001); XCTAssertEqual(tall.width, 100.0 / 3, accuracy: 0.001)
        XCTAssertEqual(tall.midX, slot.midX, accuracy: 0.001)
        for rect in [wide, tall] { XCTAssertTrue(slot.insetBy(dx: -0.001, dy: -0.001).contains(rect)) }
    }
    private func solidImage(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }
    func testThumbnailsDrawFramelessWithoutACardOrBorder() throws {
        _ = NSApplication.shared
        let view = DropShelfView(frame: NSRect(x: 0, y: 0, width: 216, height: 228))
        let area = DropShelf.previewArea(in: view.bounds)
        // One file with a wide thumbnail: the image is the preview, nothing is
        // drawn above or below it inside the slot.
        view.files = [URL(fileURLWithPath: "/synthetic/wide.png")]
        view.preview = solidImage(NSSize(width: 200, height: 100))
        let slot = try XCTUnwrap(DropShelf.stackLayout(count: 1, in: area).first?.frame)
        let image = DropShelf.framelessRect(imageSize: NSSize(width: 200, height: 100), in: slot)
        let bitmap = try render(view)
        let surface = try XCTUnwrap(bitmap.colorAt(x: 20, y: 227 - 120)?.usingColorSpace(.deviceRGB))
        let centre = try XCTUnwrap(bitmap.colorAt(x: Int(image.midX), y: 227 - Int(image.midY))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(centre.redComponent, 0.6); XCTAssertLessThan(centre.greenComponent, 0.3)
        var lighter = 0, checked = 0
        for x in Int(slot.minX + 4)..<Int(slot.maxX - 4) {
            for y in Array(Int(slot.minY + 2)..<Int(image.minY - 6)) + Array(Int(image.maxY + 6)..<Int(slot.maxY - 2)) {
                checked += 1
                guard let color = bitmap.colorAt(x: x, y: 227 - y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > surface.redComponent + 0.05 || color.greenComponent > surface.greenComponent + 0.05 ||
                    color.blueComponent > surface.blueComponent + 0.05 { lighter += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertEqual(lighter, 0, "No card background around a thumbnail")
        // Several files with thumbnails: no light border and no symbol, only the images.
        let files = (1...3).map { URL(fileURLWithPath: "/synthetic/\($0).png") }
        view.files = files; view.preview = nil
        for file in files { view.previews[file] = solidImage(NSSize(width: 160, height: 90)) }
        XCTAssertEqual(try brightPixels(view, in: area), 0, "Thumbnails are not boxed")
        // Until thumbnails arrive the placeholders still show their symbols.
        view.previews = [:]
        XCTAssertGreaterThan(try brightPixels(view, in: area), 100)
    }
}
