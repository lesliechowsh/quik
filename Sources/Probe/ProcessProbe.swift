import Foundation
import Darwin

struct RawProcess {
    var pid: pid_t
    var name: String
    var cpuNs: UInt64
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
    var footprintBytes: UInt64
}

enum ProcessProbe {
    static func readAll() -> [RawProcess] {
        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer { buf -> Int in
            Int(quik_list_pids(buf.baseAddress, Int32(capacity)))
        }
        guard count > 0 else { return [] }

        var out: [RawProcess] = []
        out.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for index in 0..<min(count, capacity) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var usage = quik_proc_usage()
            guard quik_proc_usage_read(pid, &usage) == 0, usage.ok != 0 else { continue }
            out.append(
                RawProcess(
                    pid: pid,
                    name: processName(pid, &nameBuffer),
                    cpuNs: usage.cpu_ns,
                    diskReadBytes: usage.disk_read_bytes,
                    diskWriteBytes: usage.disk_write_bytes,
                    footprintBytes: usage.footprint_bytes
                )
            )
        }
        return out
    }

    private static func processName(_ pid: pid_t, _ buffer: inout [CChar]) -> String {
        buffer[0] = 0
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
