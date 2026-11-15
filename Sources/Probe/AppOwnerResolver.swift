import AppKit
import Darwin

enum AppOwnerResolver {
    private static var cache: [pid_t: AppIdentity] = [:]

    static func resolve(_ pids: [pid_t]) -> [pid_t: AppIdentity] {
        var result: [pid_t: AppIdentity] = [:]
        var alive = Set<pid_t>()
        for pid in pids {
            alive.insert(pid)
            if let hit = cache[pid] {
                result[pid] = hit
                continue
            }
            if let resolved = lookup(pid) {
                cache[pid] = resolved
                result[pid] = resolved
            }
        }
        cache = cache.filter { alive.contains($0.key) }
        return result
    }

    private static func lookup(_ pid: pid_t) -> AppIdentity? {
        let processName = name(of: pid)
        var owner: (name: String, path: String, pid: pid_t)?
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               let url = app.bundleURL,
               url.pathExtension == "app" {
                let appName = app.localizedName ?? url.deletingPathExtension().lastPathComponent
                if let existing = owner, !existing.path.hasPrefix(url.path) { break }
                owner = (appName, url.path, current)
            }
            let next = parent(of: current)
            guard next > 1, next != current else { break }
            current = next
        }
        if let owner {
            return AppIdentity(name: owner.name, bundlePath: owner.path, role: role(for: processName), ownerPid: owner.pid)
        }
        if let bundle = appBundle(inPath: path(of: pid)) {
            let appName = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            return AppIdentity(name: appName, bundlePath: bundle, role: role(for: processName))
        }
        if let systemName = systemName(for: processName) {
            return AppIdentity(name: systemName, bundlePath: nil, role: nil, isSystem: true)
        }
        return AppIdentity(name: processName, bundlePath: nil, role: workingDirectoryRole(of: pid))
    }

    private static func workingDirectoryRole(of pid: pid_t) -> ProcessRole? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
        }
        let folder = URL(fileURLWithPath: path).lastPathComponent
        guard !folder.isEmpty, folder != "/", folder != NSUserName() else { return nil }
        return .workingDirectory(folder)
    }

    private static func appBundle(inPath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.upperBound].dropLast())
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, 4096) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func role(for processName: String) -> ProcessRole? {
        Copy.helperRole(processName)
    }

    private static func systemName(for processName: String) -> String? {
        Copy.systemProcessName(processName)
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, 256) > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }
}
