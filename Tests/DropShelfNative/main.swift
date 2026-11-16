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
    var received: [URL] = []
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        received = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !received.isEmpty
    }
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
    var downloadsRoot: URL?
    var lastPoint = CGPoint.zero
    var finished = false
    var packagedApp: NSRunningApplication?
    var finderFixtures: [URL] = []
    var finderTrial = 0
    var packagedMode: Bool { CommandLine.arguments.count > 1 }
    func finish(_ message: String, success: Bool) {
        guard !finished else { return }; finished = true
        post(.leftMouseUp, at: lastPoint)
        shelf.stop(); window?.orderOut(nil)
        if !success, let root, let diagnostics = try? String(contentsOf: root.appendingPathComponent("host-diagnostics.json")) {
            print("::notice title=Independent shelf host::\(diagnostics)")
        }
        if let packagedApp, !packagedApp.isTerminated { packagedApp.terminate() }
        if let root { try? FileManager.default.removeItem(at: root) }
        if let downloadsRoot { try? FileManager.default.removeItem(at: downloadsRoot) }
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
            var fixtureRoot = root!
            let origin = ProcessInfo.processInfo.environment["CLIPBOARDLINE_NATIVE_FIXTURE_ROOT"] ?? "temporary"
            if origin == "downloads" {
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                let directory = downloads.appendingPathComponent("Clipperline-native-test-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                downloadsRoot = directory; fixtureRoot = directory
            } else if origin != "temporary" {
                throw CocoaError(.fileReadInvalidFileName)
            }
            print("Native shelf environment: macOS=\(ProcessInfo.processInfo.operatingSystemVersionString), origin=\(origin), packaged=\(packagedMode)"); fflush(stdout)
            let file = fixtureRoot.appendingPathComponent("Synthetic.txt")
            try Data("original synthetic file".utf8).write(to: file)
            let folder = fixtureRoot.appendingPathComponent("Synthetic Folder", isDirectory: true)
            let bundle = fixtureRoot.appendingPathComponent("Synthetic Application.app", isDirectory: true)
            for directory in [folder, bundle] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("original folder contents".utf8).write(to: directory.appendingPathComponent("Marker.txt"))
            }
            finderFixtures = [file, folder, bundle]
            source = NativeSource(frame: NSRect(x: 0, y: 0, width: 260, height: 180)); source.file = file
            window = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 260, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Synthetic drag source"; window.contentView = source
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if packagedMode {
                window.orderOut(nil)
                Task { await self.launchPackagedApp() }
            } else {
                shelf.start()
                Task { await self.run() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 50) { self.finish("Native drag timed out", success: false) }
        } catch { finish("Could not create synthetic native fixture: \(error)", success: false) }
    }
    func launchPackagedApp() async {
        do {
            // Match a user's Finder launch and await LaunchServices readiness,
            // rather than assuming a raw executable is ready after two seconds.
            let applicationURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let expectedIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
            guard let expectedIdentifier, ["org.clipboardline.community", "org.clipboardline.native-shelf-host"].contains(expectedIdentifier) else { finish("Unexpected packaged fixture identity", success: false); return }
            let configuration = NSWorkspace.OpenConfiguration()
            if expectedIdentifier == "org.clipboardline.native-shelf-host" { configuration.arguments = [root.appendingPathComponent("host-diagnostics.json").path] }
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: configuration)
            packagedApp = app
            for _ in 0..<100 {
                if app.isFinishedLaunching || app.isTerminated { break }
                await pause(0.1)
            }
            guard app.bundleIdentifier == expectedIdentifier, app.isFinishedLaunching, !app.isTerminated else {
                finish("Packaged application did not finish launching: ready=\(app.isFinishedLaunching), terminated=\(app.isTerminated)", success: false); return
            }
            print("Packaged launch: LaunchServices reports the target application ready"); fflush(stdout)
            if expectedIdentifier == "org.clipboardline.community" {
                // A clean runner gets the normal screenshot-onboarding modal.
                // Decline it through the real UI; never alter privacy settings.
                let application = AXUIElementCreateApplication(app.processIdentifier)
                var declined = false
                for _ in 0..<30 {
                    var budget = 1000
                    if let button = findButton(in: application, title: "Not now", budget: &budget) {
                        declined = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                        break
                    }
                    await pause(0.1)
                }
                guard declined else { finish("Could not decline the fresh installation's screenshot setup through its UI", success: false); return }
                await pause(0.3)
            }
            await runFinder()
        } catch { finish("LaunchServices could not open the packaged application: \(error)", success: false) }
    }
    func run() async {
        print("Native shelf fixture: Starting AppKit source drag"); fflush(stdout)
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
    func findButton(in element: AXUIElement, title: String, budget: inout Int) -> AXUIElement? {
        guard budget > 0 else { return nil }; budget -= 1
        if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
           attribute(element, kAXTitleAttribute) as? String == title { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let button = findButton(in: child, title: title, budget: &budget) { return button }
        }
        return nil
    }
    func finderItemPoint(in element: AXUIElement, name: String, budget: inout Int) -> CGPoint? {
        guard budget > 0 else { return nil }; budget -= 1
        // Finder commonly hides an application's .app extension in its label.
        // Fixture names are unique even when their extension is hidden.
        let labels: Set<String> = [name, (name as NSString).deletingPathExtension]
        let named = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].contains { key in
            guard let label = attribute(element, key) as? String else { return false }
            return labels.contains(label)
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
    func visibleShelfFrame() -> NSRect? {
        guard let packagedApp else { return NSApp.windows.first { $0.isVisible && $0.contentView is DropShelfView }?.frame }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == packagedApp.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.width - 216) < 2, abs(rect.height - 228) < 2 else { continue }
            return NSRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
    func moveDrag(from start: CGPoint, to end: CGPoint) async {
        for step in 1...20 {
            let ratio = Double(step) / 20
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * ratio, y: start.y + (end.y - start.y) * ratio))
            await pause(0.03)
        }
        await pause(0.3); post(.leftMouseUp, at: end); await pause(1)
    }
    func runFinder() async {
        // This is a separate application's real file source, not injected drop
        // callbacks. Only the generated test directory is opened in Finder.
        guard AXIsProcessTrusted() else { finish("Native AppKit source passed, but the CI desktop does not authorize Finder accessibility; Finder acceptance is unverified.", success: false); return }
        print("Native shelf fixture: Starting Finder drag"); fflush(stdout)
        shelf.dismiss(); window.orderOut(nil); source.received = []
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
        var frame: NSRect?
        for _ in 0..<20 {
            frame = visibleShelfFrame()
            if frame != nil { break }; await pause(0.1)
        }
        guard let frame else {
            if let packagedApp {
                let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                let geometry = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == packagedApp.processIdentifier }.prefix(12).compactMap { info -> String? in
                    guard let bounds = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                    return "\(Int(rect.width))x\(Int(rect.height)):visible=\(info[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                }
                print("::notice title=Packaged window diagnostics::ready=\(packagedApp.isFinishedLaunching), terminated=\(packagedApp.isTerminated), windows=\(geometry.joined(separator: ","))"); fflush(stdout)
            }
            finish("Finder drag did not automatically reveal the shelf", success: false); return
        }
        let target = NSApp.windows.first { $0.isVisible && $0.contentView is DropShelfView }?.contentView as? DropShelfView
        let beforeEntries = target?.nativeEntries ?? 0, beforePreparations = target?.nativePreparations ?? 0, beforeDrops = target?.nativeDropAttempts ?? 0
        let end = globalPoint(NSPoint(x: frame.minX + 40, y: frame.minY + 70))
        await moveDrag(from: start, to: end)
        if packagedMode { await verifyPackagedDragOut(frame: frame); return }
        guard let target else { finish("Missing local shelf diagnostics", success: false); return }
        let summary = "Finder: entries=\(target.nativeEntries - beforeEntries), prepare=\(target.nativePreparations - beforePreparations), drops=\(target.nativeDropAttempts - beforeDrops), mask=\(target.nativeSourceMask.rawValue), stored=\(shelf.model.files.count)"
        guard shelf.model.files.map(\.path) == [source.file.path], visibleShelfFrame() != nil else { finish(summary, success: false); return }
        guard originalPreserved() else { finish("Finder source changed", success: false); return }
        await nextFinderTrial(summary)
    }
    func verifyPackagedDragOut(frame: NSRect) async {
        guard visibleShelfFrame() != nil else { finish("Packaged application rejected the Finder drop; the empty shelf disappeared", success: false); return }
        let screen = NSScreen.screens.first!.visibleFrame
        let x = frame.midX < screen.midX ? screen.maxX - 300 : screen.minX + 40
        window.setFrameOrigin(NSPoint(x: x, y: screen.midY - 90))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        await pause(0.4)
        let start = globalPoint(NSPoint(x: frame.midX, y: frame.minY + 130))
        let end = globalPoint(window.convertPoint(toScreen: NSPoint(x: 100, y: 90)))
        post(.mouseMoved, at: start); await pause(0.1)
        post(.leftMouseDown, at: start); await pause(0.1)
        await moveDrag(from: start, to: end)
        guard source.received.map(\.path) == [source.file.path] else { finish("Packaged application did not return the stored Finder file through a native drag", success: false); return }
        guard originalPreserved() else { finish("Packaged application changed the original", success: false); return }
        await nextFinderTrial("Packaged app: real Finder drop accepted, native drag-out accepted by another process, original preserved")
    }
    func originalPreserved() -> Bool {
        let marker = finderTrial == 0 ? source.file! : source.file.appendingPathComponent("Marker.txt")
        return (try? String(contentsOf: marker)) == (finderTrial == 0 ? "original synthetic file" : "original folder contents")
    }
    func nextFinderTrial(_ summary: String) async {
        let kind = ["file", "folder", "application bundle"][finderTrial]
        print("::notice title=Native Finder \(kind)::\(summary)"); fflush(stdout)
        if packagedMode, let frame = visibleShelfFrame() {
            let close = globalPoint(NSPoint(x: frame.minX + 23, y: frame.maxY - 23))
            post(.mouseMoved, at: close); post(.leftMouseDown, at: close)
            await pause(0.1); post(.leftMouseUp, at: close)
        } else { shelf.dismiss() }
        await pause(0.4)
        guard visibleShelfFrame() == nil else { finish("Closing the shelf did not dismiss it", success: false); return }
        finderTrial += 1
        guard finderTrial < finderFixtures.count else { finish("All real Finder file, folder and application-bundle drops passed", success: true); return }
        source.file = finderFixtures[finderTrial]
        await runFinder()
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = NativeHarness()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
