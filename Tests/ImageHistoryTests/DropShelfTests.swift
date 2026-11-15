import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class DropShelfTests: HistoryTestCase {
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
