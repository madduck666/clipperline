import AppKit
import ApplicationServices

// This executable compiles the shipping DropShelf.swift directly. Only strings
// and synthetic drag-source windows belong to the fixture, not a second shelf.
func L(_ key: String) -> String { key }

@MainActor final class NativeSource: NSView, NSDraggingSource {
    var file: URL!
    var operations: NSDragOperation = .copy
    var starts = 0
    var completed: NSDragOperation?
    private var dragging = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill(); bounds.fill()
        ("Synthetic file" as NSString).draw(at: NSPoint(x: 30, y: 75), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        dragging = true; starts += 1
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 40, height: 40), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { operations }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { completed = operation; dragging = false }
}

@MainActor final class NativeHarness: NSObject, NSApplicationDelegate {
    let shelf = DropShelfController()
    var window: NSWindow!
    var source: NativeSource!
    var root: URL!
    var lastPoint = CGPoint.zero
    var finished = false
    func finish(_ message: String, success: Bool) {
        guard !finished else { return }; finished = true
        post(.leftMouseUp, at: lastPoint)
        shelf.stop(); window?.orderOut(nil)
        if let root { try? FileManager.default.removeItem(at: root) }
        print("::\(success ? "notice" : "error") title=Native shelf drag::\(message)")
        fflush(stdout)
        exit(success ? 0 : 1)
    }
    func post(_ type: CGEventType, at point: CGPoint) {
        lastPoint = point
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }
    func globalPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CGPreflightPostEventAccess() else { finish("The CI desktop does not authorize native mouse posting; no native drag result is claimed.", success: false); return }
        do {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-shelf-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("Synthetic.txt")
            try Data("original synthetic file".utf8).write(to: file)
            source = NativeSource(frame: NSRect(x: 0, y: 0, width: 260, height: 180)); source.file = file
            window = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 260, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Synthetic drag source"; window.contentView = source
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            shelf.start()
            Task { await self.run() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 50) { self.finish("Native drag timed out", success: false) }
        } catch { finish("Could not create synthetic native fixture: \(error)", success: false) }
    }
    func run() async {
        await pause(0.8)
        let start = globalPoint(window.convertPoint(toScreen: NSPoint(x: 100, y: 90)))
        post(.mouseMoved, at: start); await pause(0.1)
        post(.leftMouseDown, at: start); await pause(0.1)
        post(.leftMouseDragged, at: CGPoint(x: start.x + 20, y: start.y)); await pause(0.4)
        guard source.starts == 1 else { finish("Posted mouse movement did not start an AppKit drag", success: false); return }
        var panel: NSWindow?
        for _ in 0..<20 {
            panel = NSApp.windows.first { $0.isVisible && $0.contentView is DropShelfView }
            if panel != nil { break }; await pause(0.1)
        }
        guard let panel, let target = panel.contentView as? DropShelfView else { finish("Actual AppKit drag did not automatically reveal the shelf", success: false); return }
        let end = globalPoint(panel.convertPoint(toScreen: NSPoint(x: 40, y: 70)))
        for step in 1...20 {
            let ratio = Double(step) / 20
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * ratio, y: start.y + (end.y - start.y) * ratio))
            await pause(0.03)
        }
        await pause(0.3); post(.leftMouseUp, at: end)
        await pause(1)
        let summary = "starts=\(source.starts), entries=\(target.nativeEntries), prepare=\(target.nativePreparations), drops=\(target.nativeDropAttempts), mask=\(target.nativeSourceMask.rawValue), result=\(source.completed?.rawValue ?? 0), stored=\(shelf.model.files.count)"
        guard shelf.model.files.map(\.path) == [source.file.path], panel.isVisible else { finish(summary, success: false); return }
        guard (try? String(contentsOf: source.file)) == "original synthetic file" else { finish("Original source changed", success: false); return }
        print("::notice title=Native AppKit source::\(summary)"); fflush(stdout)
        await runFinder()
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func finderItemPoint(in element: AXUIElement, name: String, budget: inout Int) -> CGPoint? {
        guard budget > 0 else { return nil }; budget -= 1
        let named = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].contains { key in
            (attribute(element, key) as? String) == name
        }
        if named, let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero, dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 {
                return CGPoint(x: point.x + min(dimensions.width / 2, 100), y: point.y + dimensions.height / 2)
            }
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let point = finderItemPoint(in: child, name: name, budget: &budget) { return point }
        }
        return nil
    }
    func runFinder() async {
        // This is a separate application's real file source, not injected drop
        // callbacks. Only the generated test directory is opened in Finder.
        guard AXIsProcessTrusted() else { finish("Native AppKit source passed, but the CI desktop does not authorize Finder accessibility; Finder acceptance is unverified.", success: false); return }
        shelf.dismiss(); window.orderOut(nil)
        NSWorkspace.shared.activateFileViewerSelecting([source.file])
        await pause(1.5)
        guard let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else { finish("Finder is unavailable on the CI desktop", success: false); return }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        var start: CGPoint?
        for _ in 0..<20 {
            var budget = 2000
            start = finderItemPoint(in: application, name: source.file.lastPathComponent, budget: &budget)
            if start != nil { break }; await pause(0.2)
        }
        guard let start else { finish("Could not locate the generated file in Finder's accessibility tree", success: false); return }
        post(.mouseMoved, at: start); await pause(0.1)
        post(.leftMouseDown, at: start); await pause(0.1)
        for step in 1...5 { post(.leftMouseDragged, at: CGPoint(x: start.x + Double(step) * 4, y: start.y)); await pause(0.05) }
        var panel: NSWindow?
        for _ in 0..<20 {
            panel = NSApp.windows.first { $0.isVisible && $0.contentView is DropShelfView }
            if panel != nil { break }; await pause(0.1)
        }
        guard let panel, let target = panel.contentView as? DropShelfView else { finish("Finder drag did not automatically reveal the shelf", success: false); return }
        let beforeEntries = target.nativeEntries, beforePreparations = target.nativePreparations, beforeDrops = target.nativeDropAttempts
        let end = globalPoint(panel.convertPoint(toScreen: NSPoint(x: 40, y: 70)))
        for step in 1...20 {
            let ratio = Double(step) / 20
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * ratio, y: start.y + (end.y - start.y) * ratio))
            await pause(0.03)
        }
        await pause(0.3); post(.leftMouseUp, at: end); await pause(1)
        let summary = "Finder: entries=\(target.nativeEntries - beforeEntries), prepare=\(target.nativePreparations - beforePreparations), drops=\(target.nativeDropAttempts - beforeDrops), mask=\(target.nativeSourceMask.rawValue), stored=\(shelf.model.files.count)"
        guard shelf.model.files.map(\.path) == [source.file.path], panel.isVisible else { finish(summary, success: false); return }
        guard (try? String(contentsOf: source.file)) == "original synthetic file" else { finish("Finder source file changed", success: false); return }
        finish(summary, success: true)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = NativeHarness()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
