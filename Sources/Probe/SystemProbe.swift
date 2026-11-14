import Foundation
import Darwin

struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

struct RawMemory: Equatable {
    var pageSize: UInt64
    var freePages: UInt64
    var activePages: UInt64
    var inactivePages: UInt64
    var wiredPages: UInt64
    var compressorPages: UInt64
    var swapTotal: UInt64
    var swapUsed: UInt64
    var pressureLevel: Int32
}

struct RawDisk: Equatable {
    var readBytes: UInt64
    var writeBytes: UInt64
    var busyNs: UInt64
    var deviceCount: UInt32
}

struct RawSystemSnapshot {
    var at: Date
    var cpuTicks: [CPUTicks]
    var memory: RawMemory
    var disk: RawDisk
    var thermal: ProcessInfo.ThermalState
}

enum SystemProbe {
    static func read() -> RawSystemSnapshot {
        RawSystemSnapshot(
            at: Date(),
            cpuTicks: readCPUTicks(),
            memory: readMemory(),
            disk: readDisk(),
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    static func readCPUTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }
        let boundary = Int(cpuCount) * 4
        return info.withMemoryRebound(to: UInt32.self, capacity: boundary) { p in
            (0..<Int(cpuCount)).map { i in
                CPUTicks(
                    user: p[i * 4 + Int(CPU_STATE_USER)],
                    system: p[i * 4 + Int(CPU_STATE_SYSTEM)],
                    idle: p[i * 4 + Int(CPU_STATE_IDLE)],
                    nice: p[i * 4 + Int(CPU_STATE_NICE)]
                )
            }
        }
    }

    static func readMemory() -> RawMemory {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)

        guard kr == KERN_SUCCESS else {
            return RawMemory(
                pageSize: UInt64(pageSize), freePages: 0, activePages: 0, inactivePages: 0,
                wiredPages: 0, compressorPages: 0,
                swapTotal: swap.xsu_total, swapUsed: swap.xsu_used, pressureLevel: pressure
            )
        }
        return RawMemory(
            pageSize: UInt64(pageSize),
            freePages: UInt64(stats.free_count),
            activePages: UInt64(stats.active_count),
            inactivePages: UInt64(stats.inactive_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            swapTotal: swap.xsu_total,
            swapUsed: swap.xsu_used,
            pressureLevel: pressure
        )
    }

    static func readDisk() -> RawDisk {
        var totals = quik_disk_totals()
        let ok = quik_disk_totals_read(&totals) == 0 && totals.ok != 0
        return RawDisk(
            readBytes: ok ? totals.read_bytes : 0,
            writeBytes: ok ? totals.write_bytes : 0,
            busyNs: ok ? totals.busy_ns : 0,
            deviceCount: ok ? totals.device_count : 0
        )
    }
}
