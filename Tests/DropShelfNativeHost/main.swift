import AppKit
func L(_ key: String) -> String { key }
@MainActor final class ShelfHost: NSObject, NSApplicationDelegate {
    let shelf = DropShelfController()
    var timer: Timer?
    var polls = 0, mouseDownPolls = 0, fileDragPolls = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, CommandLine.arguments.count > 1 else { return }
                self.polls += 1
                if NSEvent.pressedMouseButtons & 1 != 0 { self.mouseDownPolls += 1 }
                let board = NSPasteboard(name: .drag)
                if board.types?.contains(.fileURL) == true { self.fileDragPolls += 1 }
                let values: [String: Int] = ["polls": self.polls, "mouseDownPolls": self.mouseDownPolls, "fileDragPolls": self.fileDragPolls, "stored": self.shelf.model.files.count]
                if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); shelf.stop() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared, delegate = ShelfHost()
    app.setActivationPolicy(.accessory); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
