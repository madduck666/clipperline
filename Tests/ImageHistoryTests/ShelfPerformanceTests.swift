import AppKit
import Combine
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShelfPerformanceTests: HistoryTestCase {
    private func fixtureLine(_ f: SyntheticFixture, store: LibraryStore) -> Line {
        Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false,
             copyImage: { _ in }, copyText: { _ in }, library: store)
    }

    func testRepeatedScrollFocusDoesNotInvalidateAllRowsAndExplicitFocusStillWorks() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        _ = try store.captureText("Synthetic focus target")
        let line = fixtureLine(f, store: store)
        line.setPresentation(.all, requestFocus: false)
        var notifications = 0, focusRequests = 0
        let observation = line.objectWillChange.sink { notifications += 1 }
        defer { observation.cancel() }
        line.onFocusRequested = { focusRequests += 1 }
        for _ in 0..<500 { line.focusShelf(.images, requestFocus: false) }
        XCTAssertEqual(notifications, 0, "Scroll events inside one row must not publish unchanged active/search state")
        line.focusShelf(.texts, requestFocus: false)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(line.activeShelf, .texts)
        line.focusShelf(.texts)
        XCTAssertEqual(focusRequests, 1, "Explicit keyboard/mouse focus requests remain actionable even when the active row is unchanged")
        line.revealed = true; line.beginShelfSearch(.texts)
        XCTAssertEqual(line.searchEditingShelf, .texts)
        line.focusShelf(.texts, requestFocus: false)
        XCTAssertEqual(line.searchEditingShelf, .texts, "A scroll inside the searching row preserves its editor")
        line.focusShelf(.images, requestFocus: false)
        XCTAssertNil(line.searchEditingShelf)
    }

    func testEveryOverflowingRowAcceptsGapScrollingAcrossAllPresentations() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        _ = try store.captureImage(f.image())
        for i in 0..<10 {
            _ = try store.captureText("Synthetic gap text \(i)")
            _ = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/gap/\(i)")))
        }
        let line = fixtureLine(f, store: store)
        line.setViewportWidth(350)
        for presentation in ShelfPresentation.allCases {
            line.setPresentation(presentation, requestFocus: false)
            for (index, shelf) in presentation.shelves.enumerated() {
                let top = CGFloat(index) * Layout.panelHeight
                XCTAssertEqual(line.scrollableShelfBandContains(CGPoint(x: 220, y: top + 70)), shelf != .images,
                               "A short image row cannot suppress the overflowing text/link row beneath it")
                XCTAssertFalse(line.scrollableShelfBandContains(CGPoint(x: 220, y: top + 2)), "Top toolbar gaps still pass through")
                XCTAssertFalse(line.scrollableShelfBandContains(CGPoint(x: 220, y: top + Layout.panelHeight - 2)))
            }
            XCTAssertFalse(line.scrollableShelfBandContains(CGPoint(x: -1, y: 70)))
            XCTAssertFalse(line.scrollableShelfBandContains(CGPoint(x: 351, y: 70)))
            XCTAssertFalse(line.scrollableShelfBandContains(CGPoint(x: 220, y: line.panelHeight + 1)))
        }
    }

    func testImageProjectionCacheReflectsPinEditsRemovalAndUndoWithoutLosingOrder() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let first = try store.captureImage(f.image()); f.date.addTimeInterval(1)
        let second = try store.captureImage(f.image())
        let line = fixtureLine(f, store: store)
        XCTAssertEqual(line.displayItems.map(\.id), [second.id, first.id])
        line.setFavoritesOnly(true)
        XCTAssertTrue(line.displayItems.isEmpty)
        try store.toggleFavorite([first.id])
        XCTAssertEqual(line.displayItems.map(\.id), [first.id])
        try store.update(first.id) { $0.title = "Updated retained title" }
        XCTAssertEqual(line.displayItems.first?.title, "Updated retained title")
        try store.toggleFavorite([second.id])
        XCTAssertEqual(line.displayItems.map(\.id), [second.id, first.id])
        try store.removeFromShelf([first.id])
        XCTAssertEqual(line.displayItems.map(\.id), [second.id])
        line.setFavoritesOnly(false)
        XCTAssertEqual(line.displayItems.map(\.id), [second.id])
        _ = try store.undoShelfRemoval()
        XCTAssertEqual(line.displayItems.map(\.id), [second.id, first.id])
    }

    func testRepeatedThreeShelfOpenCloseLeavesInactiveRowsQuietAndRestoresSingleSelection() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let image = try store.captureImage(f.image())
        for i in 0..<12 {
            _ = try store.captureText("Toggle text \(i)")
            _ = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/toggle/\(i)")))
        }
        let line = fixtureLine(f, store: store)
        line.setPresentation(.all, requestFocus: false)
        var inactiveChanges = 0
        let text = line.texts.objectWillChange.sink { inactiveChanges += 1 }
        let link = line.links.objectWillChange.sink { inactiveChanges += 1 }
        defer { text.cancel(); link.cancel() }
        for _ in 0..<50 {
            line.revealed = true
            XCTAssertEqual(line.activeShelf, .images)
            XCTAssertEqual(line.selectedIDs, [image.id])
            XCTAssertTrue(line.texts.selectedIDs.isEmpty && line.links.selectedIDs.isEmpty)
            line.revealed = false
            XCTAssertTrue(line.selectedIDs.isEmpty)
            XCTAssertNil(line.focusedID)
        }
        XCTAssertEqual(inactiveChanges, 0, "Opening/closing an unchanged image selection must not invalidate either inactive row")
        XCTAssertEqual(line.texts.displayEntries.count, 12)
        XCTAssertEqual(line.links.displayEntries.count, 12)
    }

    func testSettlingTheLineRedrawsEveryRowOnceWithoutTouchingTheirModels() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        _ = try store.captureImage(f.image())
        _ = try store.captureText("Settle text")
        _ = try store.captureLink(try XCTUnwrap(URL(string: "https://example.com/settle")))
        let line = fixtureLine(f, store: store)
        line.setPresentation(.all, requestFocus: false)
        XCTAssertTrue(line.shelfSettled, "Mounted without the app, the line counts as resting and keeps its glass")
        var lineChanges = 0, rowModelChanges = 0
        let own = line.objectWillChange.sink { lineChanges += 1 }
        let text = line.texts.objectWillChange.sink { rowModelChanges += 1 }
        let link = line.links.objectWillChange.sink { rowModelChanges += 1 }
        defer { own.cancel(); text.cancel(); link.cancel() }
        let resting = Shelf.allCases.map { ShelfRenderState(line: line, shelf: $0) }
        line.shelfSettled = false
        let moving = Shelf.allCases.map { ShelfRenderState(line: line, shelf: $0) }
        XCTAssertEqual(lineChanges, 1, "One publish switches every card to its flat fill for the slide")
        for index in resting.indices {
            XCTAssertNotEqual(resting[index], moving[index], "Text and link rows redraw too, although they compare render state only")
        }
        line.shelfSettled = true
        XCTAssertEqual(lineChanges, 2)
        XCTAssertEqual(Shelf.allCases.map { ShelfRenderState(line: line, shelf: $0) }, resting, "Resting again restores the same row state")
        XCTAssertEqual(rowModelChanges, 0, "The slide never invalidates the text or link histories")
    }

    func testClosingActiveSearchClearsItBeforeFreshOpenChoosesImages() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let image = try store.captureImage(f.image())
        _ = try store.captureText("Search closure remains fresh")
        let line = fixtureLine(f, store: store)
        line.setPresentation(.all, requestFocus: false)
        line.revealed = true
        line.focusShelf(.texts, requestFocus: false)
        line.beginShelfSearch(.texts)
        XCTAssertTrue(line.isShelfSearchActive)
        line.revealed = false
        XCTAssertFalse(line.isShelfSearchActive)
        XCTAssertNil(line.searchEditingShelf)
        XCTAssertEqual(line.shelfSearchQuery, "")
        line.revealed = true
        XCTAssertEqual(line.activeShelf, .images)
        XCTAssertEqual(line.focusedID, image.id)
        XCTAssertEqual(line.selectedIDs, [image.id])
        XCTAssertTrue(line.texts.selectedIDs.isEmpty && line.links.selectedIDs.isEmpty)
    }

}
