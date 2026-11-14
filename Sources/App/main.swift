import AppKit

private func mainTrace(_ text: String) {
    guard ProcessInfo.processInfo.environment["QUIK_TRACE"] == "1" else { return }
    let path = "/tmp/quik-trace.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
        try? handle.close()
    } else {
        try? (text + "\n").write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainTrace("didFinishLaunching")
        let preview = ProcessInfo.processInfo.environment["QUIK_PREVIEW"]
        statusController = StatusItemController(preview: preview)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.openPanel()
        return false
    }
}

mainTrace("main start")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
