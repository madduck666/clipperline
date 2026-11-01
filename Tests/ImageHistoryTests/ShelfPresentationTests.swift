import AppKit
import SwiftUI
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class ShelfPresentationTests: HistoryTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate(), "Native shelf presentation did not settle")
    }

    func testNativeVisibilityKeepsWindowContentAndHitCoordinatesFixed() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 780))
        let child = NSView(frame: NSRect(x: 30, y: 50, width: 100, height: 80))
        content.addSubview(child)
        let panel = LinePanel(content: content)
        defer { panel.contentView = nil }
        panel.setFrame(NSRect(x: -900, y: 250, width: 900, height: 780), display: false)
        let originalFrame = panel.frame, originalBounds = content.bounds, originalContentFrame = content.frame
        let point = child.convert(NSPoint(x: 40, y: 40), to: content)
        let originalHit = content.hitTest(point)
        XCTAssertFalse(panel.isVisible, "Preparation must happen before the caller orders the shelf front")
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12), "The first committed frame starts above the display")
        XCTAssertNotNil(panel.contentView?.layer)
        XCTAssertTrue(panel.contentView?.layer?.masksToBounds == true)
        for on in [false, true, false, true] {
            panel.setShelfRevealed(on, animated: false)
            XCTAssertEqual(panel.frame, originalFrame, "Visibility must not move into a display above the shelf")
            XCTAssertEqual(content.bounds, originalBounds)
            XCTAssertEqual(content.frame, originalContentFrame)
            XCTAssertTrue(content.superview === panel.contentView, "The retained hosting view lives inside the fixed compositor")
            XCTAssertTrue(content.hitTest(point) === originalHit)
            XCTAssertEqual(panel.shelfModelOffset, on ? 0 : -(panel.contentHeight + 12))
            XCTAssertEqual(panel.alphaValue, 1, "Reveal must move the layer tree rather than fade the window")
            XCTAssertFalse(panel.isShelfTransitioning)
        }
        panel.setShelfRevealed(false, animated: false)
        panel.contentHeight = 3 * Layout.panelHeight
        XCTAssertEqual(panel.shelfModelOffset, -(3 * Layout.panelHeight + 12), "A hidden row-count change must remain completely above the display")
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertEqual(content.bounds, originalBounds)
        panel.setShelfRevealed(true, animated: false)
        panel.contentHeight = Layout.panelHeight
        XCTAssertEqual(panel.shelfModelOffset, 0, "Visible capacity changes must retain their resting position")
    }

    func testRapidVisibilityReversalCannotRunAnEarlierCloseCompletion() throws {
        _ = NSApplication.shared
        for reduceMotion in [false, true] {
            let panel = LinePanel(content: NSView(), reduceMotion: { reduceMotion })
            defer { panel.contentView = nil }
            var closed = 0, opened = 0
            var scrolls = 0, mouseCaptures = 0, keys = 0
            panel.onScroll = { _, _, _ in scrolls += 1 }
            panel.onBeforeMouseKeyFocus = { mouseCaptures += 1 }
            let cgWheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
            let wheel = try XCTUnwrap(NSEvent(cgEvent: cgWheel))
            // Both requests happen in one event turn, as with a queued global
            // shortcut. An earlier asynchronous completion must not hide the row.
            panel.setShelfRevealed(false) { closed += 1 }
            panel.setShelfRevealed(true) { opened += 1 }
            XCTAssertEqual(panel.shelfModelOffset, 0)
            XCTAssertEqual(panel.isShelfTransitioning, !reduceMotion)
            if !reduceMotion {
                XCTAssertTrue(panel.ignoresMouseEvents, "Model hit coordinates must not accept pointer actions while the cards move")
                XCTAssertNotNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(click)
                panel.sendEvent(wheel)
                XCTAssertEqual(mouseCaptures, 0, "Queued pointer events must not capture a field at the untranslated model position")
                XCTAssertEqual(scrolls, 0, "Queued scrolling must not navigate the untranslated shelf row")
                panel.keyboardFocusAllowed = true
                panel.onKey = { _ in keys += 1; return true }
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
                XCTAssertTrue(panel.routeKey(key, isFocused: true))
                XCTAssertEqual(keys, 1, "Keyboard browsing remains immediate while the compositor animates")
            }
            wait { opened == 1 }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.shelfModelOffset, 0)
            XCTAssertFalse(panel.isShelfTransitioning)
            XCTAssertNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
            panel.sendEvent(wheel)
            XCTAssertEqual(scrolls, 1, "Normal row scrolling resumes after the compositor settles")
            // Reverse a real open-to-close request before its completion can
            // order the panel out. Detached layers do not promise a rendered
            // presentation position, so visual continuity is a live-test gate.
            panel.setShelfRevealed(false) { closed += 1 }
            panel.setShelfRevealed(true) { opened += 1 }
            wait { opened == 2 }
            XCTAssertEqual(closed, 0)
            XCTAssertEqual(panel.shelfModelOffset, 0)
            panel.setShelfRevealed(false) { closed += 1 }
            wait { closed == 1 }
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
            XCTAssertFalse(panel.isShelfTransitioning)
        }
    }

    func testReducedMotionIsImmediateAndPresentationDoesNotClaimKeyboardOwnership() throws {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView(), reduceMotion: { true })
        defer { panel.contentView = nil }
        var captures = 0
        panel.onBeforeMouseKeyFocus = { captures += 1 }
        panel.keyboardFocusAllowed = false
        panel.setShelfRevealed(false)
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.isShelfTransitioning)
        panel.setShelfRevealed(true)
        XCTAssertEqual(panel.shelfModelOffset, 0)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.isShelfTransitioning)
        XCTAssertNil(panel.contentView?.layer?.animation(forKey: LinePanel.shelfAnimationKey))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.keyboardFocusAllowed)
        XCTAssertEqual(captures, 0, "Exact paste-target capture stays at the caller's focus boundary")
        panel.keyboardFocusAllowed = true
        panel.setShelfRevealed(false)
        XCTAssertTrue(panel.keyboardFocusAllowed, "The AppDelegate still owns focus release and return")
        XCTAssertEqual(panel.shelfModelOffset, -(panel.contentHeight + 12))
    }

    func testOnlyTheMenuBarIconOpensTheLineFromAPointer() {
        // A synthetic 1440x900 screen whose 24 point menu bar holds the icon.
        let icon = NSRect(x: 1200, y: 876, width: 30, height: 24)
        XCTAssertTrue(AppDelegate.pointerRestsOnStatusIcon(NSPoint(x: 1215, y: 888), icon: icon),
            "Resting on the line's menu bar icon starts the reveal dwell")
        XCTAssertTrue(AppDelegate.pointerRestsOnStatusIcon(NSPoint(x: 1215, y: 900), icon: icon),
            "A pointer pushed against the top edge over the icon still counts")
        for point in [NSPoint(x: 20, y: 888), NSPoint(x: 700, y: 899), NSPoint(x: 1185, y: 888),
                      NSPoint(x: 1245, y: 888), NSPoint(x: 1215, y: 860)] {
            XCTAssertFalse(AppDelegate.pointerRestsOnStatusIcon(point, icon: icon),
                "Elsewhere in or below the menu bar the line stays where it is: \(point)")
        }
        XCTAssertFalse(AppDelegate.pointerRestsOnStatusIcon(NSPoint(x: 1215, y: 888), icon: nil),
            "Without an icon on screen the pointer never opens the line")
        XCTAssertFalse(AppDelegate.pointerRestsOnStatusIcon(.zero, icon: .zero))
    }

    func testShelfBackdropLetsClicksReachTheDesktopWhileCardsStillTakeThem() throws {
        _ = NSApplication.shared
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let first = try store.captureImage(f.image()); f.date.addTimeInterval(1)
        let second = try store.captureImage(f.image())
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, library: store)
        line.revealed = true
        let width: CGFloat = 1440
        let host = NSHostingView(rootView: LineView(line: line)); host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.contentHeight = line.panelHeight
        panel.setFrame(NSRect(x: -10000, y: -10000, width: width, height: line.panelHeight), display: false)
        defer { line.revealed = false; panel.contentView = nil }
        // An unordered offscreen panel never runs onAppear; give the line the
        // screen width it gets when shown, so the swipe band is measured too.
        line.setViewportWidth(width)
        let deadline = Date().addingTimeInterval(5)
        while (line.hitRects[first.id] == nil || line.hitRects[second.id] == nil) && Date() < deadline {
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let card = try XCTUnwrap(line.hitRects[first.id])
        XCTAssertTrue(line.acceptsPointer(at: CGPoint(x: card.midX, y: card.midY)), "A card still takes the pointer")
        XCTAssertEqual(line.maximumScrollOffset, 0, "Two cards do not overflow, so no swipe band is claimed")
        // Inside the row's backdrop, away from every card and control: the
        // backdrop is only drawn, the click belongs to whatever is underneath.
        for point in [CGPoint(x: width - 60, y: Layout.panelHeight - 30), CGPoint(x: width / 2 + 200, y: Layout.panelHeight / 2),
                      CGPoint(x: card.midX, y: Layout.panelHeight - 8)] {
            XCTAssertFalse(line.acceptsPointer(at: point), "The shelf backdrop must not catch clicks at \(point)")
        }
    }

    func testShelfBackdropDarknessIsAdjustableAndRemembered() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false)
        XCTAssertEqual(line.backdropDarkness, ShelfBackdrop.defaultDarkness, accuracy: 0.0001,
            "A fresh install starts at the default darkness")
        line.setBackdropDarkness(0.72)
        let reopened = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false)
        XCTAssertEqual(reopened.backdropDarkness, 0.72, accuracy: 0.0001, "The chosen darkness survives a relaunch")
        line.setBackdropDarkness(5)
        XCTAssertEqual(line.backdropDarkness, ShelfBackdrop.maximumDarkness, accuracy: 0.0001,
            "The band never becomes an opaque wall")
        line.setBackdropDarkness(-1)
        XCTAssertEqual(line.backdropDarkness, 0, accuracy: 0.0001, "Zero turns the band off")
        line.setBackdropDarkness(.nan)
        XCTAssertEqual(line.backdropDarkness, ShelfBackdrop.defaultDarkness, accuracy: 0.0001)
    }
}
