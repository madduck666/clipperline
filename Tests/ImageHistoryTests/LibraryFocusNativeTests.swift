import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class LibraryFocusNativeTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate())
    }
    private func library(_ fixture: SyntheticFixture, count: Int = 12) throws -> LibraryStore {
        let store = try LibraryStore(defaults: fixture.defaults, inbox: fixture.inbox, now: { fixture.date })
        for index in 0..<count {
            let value = try XCTUnwrap(store.captureText("Keyboard fixture \(index)"))
            try store.retain([value.id])
        }
        return store
    }
    private func host(_ controller: NSViewController) -> (window: NSWindow, editor: NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        controller.view.frame = NSRect(x: 0, y: 50, width: 900, height: 650)
        root.addSubview(controller.view)
        let editor = NSTextField(string: "An inspector field keeps its keyboard focus")
        editor.frame = NSRect(x: 12, y: 10, width: 650, height: 24); root.addSubview(editor)
        window.contentView = root; root.layoutSubtreeIfNeeded()
        return (window, editor)
    }
    private func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
        window.firstResponder === field || window.firstResponder === field.currentEditor()
    }
    func testGridSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let store = try library(fixture), model = LibraryModel(store: store)
        let line = Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store)
        let controller = LibraryCollectionController(model: model, line: line), host = host(controller)
        defer { host.window.contentView = nil }
        wait { model.ids.count == 12 && controller.collection.numberOfItems(inSection: 0) == 12 }
        XCTAssertTrue(host.window.makeFirstResponder(host.editor)); host.editor.selectText(nil)
        XCTAssertTrue(isEditing(host.editor, in: host.window))
        XCTAssertTrue(model.select(model.ids[3]))
        wait { controller.collection.selectionIndexPaths == [IndexPath(item: 3, section: 0)] }
        XCTAssertTrue(isEditing(host.editor, in: host.window), "Revealing a selection must not pull focus out of an editor")
        model.onContentFocus?()
        XCTAssertTrue(host.window.firstResponder === controller.collection)
        XCTAssertEqual(model.selectedIDs, [model.ids[3]])
    }
    func testListSelectionRevealDoesNotStealEditorFocusAndExplicitEntryStillWorks() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let store = try library(fixture), model = LibraryModel(store: store)
        let controller = LibraryTableController(model: model), host = host(controller)
        defer { host.window.contentView = nil }
        wait { model.ids.count == 12 && controller.table.numberOfRows == 12 }
        XCTAssertTrue(host.window.makeFirstResponder(host.editor)); host.editor.selectText(nil)
        XCTAssertTrue(isEditing(host.editor, in: host.window))
        XCTAssertTrue(model.select(model.ids[4]))
        wait { controller.table.selectedRowIndexes == IndexSet(integer: 4) }
        XCTAssertTrue(isEditing(host.editor, in: host.window), "Revealing a selection must not pull focus out of an editor")
        model.onContentFocus?()
        XCTAssertTrue(host.window.firstResponder === controller.table)
        XCTAssertEqual(model.selectedIDs, [model.ids[4]])
    }
    private func key(_ code: UInt16, _ text: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func testNativeContentDoesNotReviveDisabledKeysOrInterceptAnEditorsEquivalents() throws {
        _ = NSApplication.shared
        for list in [false, true] {
            let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
            let store = try library(fixture), model = LibraryModel(store: store)
            let line = Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store)
            let controller: NSViewController = list ? LibraryTableController(model: model) : LibraryCollectionController(model: model, line: line)
            let host = host(controller); defer { host.window.contentView = nil }
            wait { model.ids.count == 12 && (list ? (controller as! LibraryTableController).table.numberOfRows == 12 : (controller as! LibraryCollectionController).collection.numberOfItems(inSection: 0) == 12) }
            let native: NSView = (controller as? LibraryTableController)?.table ?? (controller as! LibraryCollectionController).collection
            XCTAssertTrue(model.select(model.ids[0])); model.onContentFocus?()
            XCTAssertTrue(host.window.firstResponder === native)
            try model.keyboardBindings.set([], for: .next)
            native.keyDown(with: key(124, "\u{F703}"))
            XCTAssertEqual(model.focusedID, model.ids[0]); XCTAssertEqual(model.selectedIDs, [model.ids[0]])
            try model.keyboardBindings.set([KeyShortcut(keyCode: 38, modifiers: 0, keyLabel: "J")], for: .next)
            native.keyDown(with: key(38, "j"))
            XCTAssertEqual(model.focusedID, model.ids[1]); XCTAssertEqual(model.selectedIDs, [model.ids[1]])
            try model.keyboardBindings.set([], for: .selectAll)
            XCTAssertTrue(native.performKeyEquivalent(with: key(0, "a", [.command])))
            XCTAssertEqual(model.selectedIDs, [model.ids[1]], "The native Select All fallback must stay disabled")
            XCTAssertTrue(host.window.makeFirstResponder(host.editor)); host.editor.selectText(nil)
            XCTAssertFalse(native.performKeyEquivalent(with: key(0, "a", [.command])))
            XCTAssertTrue(isEditing(host.editor, in: host.window))
        }
    }
    private func outline(in view: NSView) -> NSOutlineView? {
        if let result = view as? NSOutlineView { return result }
        return view.subviews.lazy.compactMap { self.outline(in: $0) }.first
    }
    func testSidebarKeepsNativeTreeExpansionAndCanEnterResultsWithKeyboard() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let store = try library(fixture, count: 1), record = try XCTUnwrap(store.queryIDs(LibraryQuery()).first)
        let parent = try store.createCollection("Keyboard parent"), child = try store.createCollection("Keyboard child", parent: parent)
        try store.assign([record], to: parent)
        let controller = LibraryWindowController(store: store, line: Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store))
        let window = try XCTUnwrap(controller.window), split = controller.splitController!
        defer { window.contentViewController = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let sidebar = split.sidebar!, native = try XCTUnwrap(outline(in: sidebar.view))
        controller.model.changeScope(.collection(parent)); wait { !controller.model.loading && controller.model.ids == [record] }
        XCTAssertTrue(split.focusSidebar()); XCTAssertTrue(split.isSidebarFocused)
        let node = try XCTUnwrap(native.item(atRow: native.selectedRow) as? LibrarySidebarNode)
        XCTAssertEqual(node.scope, .collection(parent)); native.collapseItem(node)
        let right = key(124, "\u{F703}")
        XCTAssertFalse(sidebar.performKeyboardEntry(right), "A collapsed folder keeps the native Right-to-expand action")
        native.keyDown(with: right); XCTAssertTrue(native.isItemExpanded(node)); XCTAssertTrue(split.isSidebarFocused)
        XCTAssertTrue(sidebar.performKeyboardEntry(key(36, "\r")))
        wait { window.firstResponder is NSCollectionView }
        XCTAssertEqual(controller.model.focusedID, record); XCTAssertEqual(controller.model.selectedIDs, [record])
        controller.model.changeScope(.collection(child)); wait { !controller.model.loading }
        XCTAssertTrue(split.focusSidebar()); XCTAssertEqual((native.item(atRow: native.selectedRow) as? LibrarySidebarNode)?.scope, .collection(child))
        XCTAssertTrue(native.isItemExpanded(node), "A nested target reveals its parent")
    }
    func testSidebarContextKeyUsesSelectedFolderAndTagMenusWithoutMovingFocus() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let store = try library(fixture, count: 1), record = try XCTUnwrap(store.queryIDs(LibraryQuery()).first)
        let folder = try store.createCollection("Keyboard folder"); try store.addTag("Keyboard tag", to: [record])
        let tag = try XCTUnwrap(store.tags().first)
        let controller = LibraryWindowController(store: store, line: Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store))
        let window = try XCTUnwrap(controller.window), split = controller.splitController!
        defer { window.contentViewController = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let sidebar = split.sidebar!; var menus = [[String]]()
        sidebar.keyboardMenuPresenter = { menu, _, _ in menus.append(menu.items.map(\.title)) }
        controller.model.changeScope(.collection(folder)); XCTAssertTrue(split.focusSidebar())
        XCTAssertTrue(sidebar.performKeyboardEntry(key(109, "", [.shift])))
        XCTAssertTrue(menus.last?.contains(L("Rename folder")) == true); XCTAssertTrue(menus.last?.contains(L("Remove folder")) == true)
        XCTAssertTrue(split.isSidebarFocused)
        controller.model.changeScope(.tag(tag.id)); XCTAssertTrue(split.focusSidebar())
        XCTAssertTrue(sidebar.performKeyboardEntry(key(110)))
        XCTAssertTrue(menus.last?.contains(L("Rename tag")) == true); XCTAssertTrue(menus.last?.contains(L("Remove tag")) == true)
        XCTAssertTrue(split.isSidebarFocused)
    }
    func testInspectorFocusRecognizesSharedFieldEditorAndSkipsEmptySelection() throws {
        _ = NSApplication.shared
        let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
        let store = try library(fixture, count: 1), controller = LibraryWindowController(store: store, line: Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store))
        let window = try XCTUnwrap(controller.window), split = controller.splitController!
        defer { window.contentViewController = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        wait { controller.model.ids.count == 1 && !controller.model.loading }
        XCTAssertFalse(split.focusInspector(), "An unselected inspector has no editable target")
        XCTAssertTrue(controller.model.select(try XCTUnwrap(controller.model.ids.first)))
        wait { window.contentView?.layoutSubtreeIfNeeded(); return split.focusInspector() }
        XCTAssertTrue(split.inspectorFocusContains(window.firstResponder))
        XCTAssertTrue(window.firstResponder is NSTextView || window.firstResponder is NSTextField)
        XCTAssertTrue(split.focusSidebar()); XCTAssertFalse(split.inspectorFocusContains(window.firstResponder))
        XCTAssertTrue(split.isSidebarFocused)
    }

    func testContentFocusRequestSurvivesAQueryCompletedBeforeTheNativeViewAttaches() throws {
        _ = NSApplication.shared
        for list in [false, true] {
            let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
            let store = try library(fixture), model = LibraryModel(store: store)
            model.listMode = list
            wait { model.ids.count == 12 && !model.loading }
            XCTAssertTrue(model.focusContent()); XCTAssertTrue(model.contentFocusPending)
            let line = Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store)
            let controller: NSViewController = list ? LibraryTableController(model: model) : LibraryCollectionController(model: model, line: line)
            _ = controller.view
            XCTAssertTrue(model.contentFocusPending, "An unattached view cannot acknowledge native keyboard focus")
            let host = host(controller); defer { host.window.makeFirstResponder(nil); host.window.contentView = nil }
            controller.viewDidAppear()
            wait { !model.contentFocusPending }
            let native: NSView = (controller as? LibraryTableController)?.table ?? (controller as! LibraryCollectionController).collection
            XCTAssertTrue(host.window.firstResponder === native)
            XCTAssertEqual(model.focusedID, model.ids.first); XCTAssertEqual(model.selectedIDs, Set(model.ids.prefix(1)))
        }
    }

    func testExplicitSearchOrSidebarEntrySupersedesPendingResultFocus() throws {
        _ = NSApplication.shared
        // swift test is a command-line host. Opt this visible-window fixture
        // into normal activation so AppKit can establish a real key editor.
        let activationPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.regular))
        defer { _ = NSApp.setActivationPolicy(activationPolicy) }
        for destination in ["command-search", "pane-search", "pane-sidebar"] {
            let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
            let store = try library(fixture, count: 1)
            let controller = LibraryWindowController(store: store,
                line: Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store))
            let model = controller.model
            let window = try XCTUnwrap(controller.window), search = controller.toolbarController.searchField
            defer {
                window.endEditing(for: nil); window.makeFirstResponder(nil)
                controller.close(); window.contentViewController = nil
            }
            // Exercise toolbar search through normal window presentation;
            // a hidden window has a different field-editor lifecycle.
            // The later query completion must preserve the new editor focus.
            controller.present()
            wait {
                window.contentView?.layoutSubtreeIfNeeded()
                // Presentation/activation is asynchronous. A visible window
                // can have a programmatic first responder before it becomes
                // key; that later transition replaces its field editor.
                return window.isVisible && window.isKeyWindow && !model.loading &&
                    !model.contentFocusPending && model.ids.count == 1 && window.firstResponder is NSCollectionView
            }
            model.onSearchFocus?(); XCTAssertTrue(isEditing(search, in: window))
            model.search = "Keyboard fixture"
            XCTAssertTrue(model.focusContent()); XCTAssertTrue(model.loading); XCTAssertTrue(model.contentFocusPending)
            switch destination {
            case "command-search": XCTAssertTrue(window.performKeyEquivalent(with: key(3, "f", [.command])))
            case "pane-search": controller.focusKeyboardPane(.search)
            default: controller.focusKeyboardPane(.sidebar)
            }
            XCTAssertFalse(model.contentFocusPending, "Explicit pane entry supersedes deferred result focus")
            if destination == "pane-sidebar" { XCTAssertTrue(controller.splitController.isSidebarFocused) }
            else { XCTAssertTrue(isEditing(search, in: window)) }
            wait { !model.loading }
            if destination == "pane-sidebar" { XCTAssertTrue(controller.splitController.isSidebarFocused) }
            else { XCTAssertTrue(isEditing(search, in: window), "The query completion must preserve the newer editor focus; destination=\(destination), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder.map { type(of: $0) }))") }
        }
    }

    func testExplicitSearchOrSidebarEntrySupersedesPendingNewNoteInspectorFocus() throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.regular))
        defer { _ = NSApp.setActivationPolicy(activationPolicy) }
        for destination in ["search", "sidebar"] {
            let fixture = try SyntheticFixture(); defer { fixture.cleanup() }
            let store = try library(fixture, count: 1)
            let controller = LibraryWindowController(store: store,
                line: Line(defaults: fixture.defaults, inbox: fixture.inbox, breeze: false, library: store))
            let model = controller.model
            let window = try XCTUnwrap(controller.window), search = controller.toolbarController.searchField
            defer {
                window.endEditing(for: nil); window.makeFirstResponder(nil)
                controller.close(); window.contentViewController = nil
            }
            controller.present()
            wait {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.isVisible && window.isKeyWindow && !model.loading && model.ids.count == 1 && window.firstResponder is NSCollectionView
            }
            let original = try XCTUnwrap(model.focusedID)
            XCTAssertTrue(window.performKeyEquivalent(with: key(45, "n", [.command])))
            XCTAssertTrue(model.loading)
            let note = try XCTUnwrap(model.focusedID)
            XCTAssertNotEqual(note, original)
            if destination == "search" {
                XCTAssertTrue(window.performKeyEquivalent(with: key(3, "f", [.command])))
                XCTAssertTrue(isEditing(search, in: window))
            } else {
                controller.focusKeyboardPane(.sidebar)
                XCTAssertTrue(controller.splitController.isSidebarFocused)
            }
            wait {
                window.contentView?.layoutSubtreeIfNeeded()
                return !model.loading && model.ids.count == 2
            }
            if destination == "search" {
                XCTAssertTrue(isEditing(search, in: window), "Command-F supersedes the new note's deferred inspector entry")
            } else {
                XCTAssertTrue(controller.splitController.isSidebarFocused, "Explicit sidebar entry supersedes the new note's deferred inspector entry")
            }
            let saved = try XCTUnwrap(store.item(note))
            XCTAssertEqual(saved.kind, .text); XCTAssertEqual(saved.text, "")
            XCTAssertNotNil(saved.retainedAt); XCTAssertNil(saved.deletedAt)
        }
    }

}
