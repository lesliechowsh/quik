import AppKit

enum CulpritActions {
    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func sample(_ culprit: Culprit, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("quik-\(culprit.name.replacingOccurrences(of: "/", with: "-"))-\(stamp).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(culprit.pid)", "3", "1", "-file", url.path]
            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.open(url)
                        completion(url)
                    } else {
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    static func quit(_ culprit: Culprit, completion: @escaping (Bool) -> Void) {
        let target = culprit.app?.ownerPid ?? culprit.pid
        if let app = NSRunningApplication(processIdentifier: target), !app.isTerminated {
            app.terminate()
        } else {
            kill(target, SIGTERM)
        }
        waitUntilGone(target, deadline: 6, completion: completion)
    }

    private static func waitUntilGone(_ pid: pid_t, deadline: TimeInterval, completion: @escaping (Bool) -> Void) {
        let started = Date()
        func check() {
            if !isRunning(pid) { return completion(true) }
            if Date().timeIntervalSince(started) >= deadline { return completion(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
        }
        check()
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

}
