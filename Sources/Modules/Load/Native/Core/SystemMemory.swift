import Darwin
import Foundation

enum MemoryPressure: Int, Sendable {
    case normal = 1, warn = 2, critical = 4

    init(level: Int) {
        self = MemoryPressure(rawValue: level) ?? .normal
    }
}

/// Итоги памяти мака — как в Мониторе активности, в целых MB.
struct MemoryTotals: Sendable {
    var totalMB: Int
    /// Занято = приложения + wired + сжатое.
    var usedMB: Int
    var appMB: Int
    var wiredMB: Int
    var compressedMB: Int
    var cachedMB: Int
    var freeMB: Int
    var swapUsedMB: Int
    var swapTotalMB: Int
    var pressure: MemoryPressure
}

struct HostInfo: Sendable {
    var chip: String
    var ramMB: Int
    var macOS: String
    var bootTime: TimeInterval
    var uptime: TimeInterval { Date().timeIntervalSince1970 - bootTime }
}

/// Память системы из ядра: host_statistics64, vm.swapusage, давление.
enum SystemMemory {
    private static let mb = 1_048_576.0
    static let pageSize: Int = sysctlInt("hw.pagesize").map(Int.init) ?? 16384
    static let totalMB: Int = Int((sysctlInt("hw.memsize") ?? 0) / 1_048_576)

    static let host = HostInfo(
        chip: sysctlString("machdep.cpu.brand_string") ?? "?",
        ramMB: totalMB,
        macOS: sysctlString("kern.osproductversion") ?? "?",
        bootTime: bootTime())

    private static func vmStats() -> vm_statistics64_data_t? {
        var vs = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vs) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? vs : nil
    }

    /// Сколько записано в своп с загрузки, MB: счётчик swapouts × размер страницы.
    static func swapoutsMB() -> Int {
        guard let vs = vmStats() else { return 0 }
        return Int((Double(vs.swapouts) * Double(pageSize) / mb).rounded())
    }

    static func read() -> MemoryTotals {
        func toMB(_ pages: Int64) -> Int { Int((Double(max(pages, 0)) * Double(pageSize) / mb).rounded()) }
        var app = 0, wired = 0, compressed = 0, cached = 0, free = 0
        if let vs = vmStats() {
            // «Приложения» в Мониторе активности — internal без purgeable; «кэш» — external + purgeable.
            app = toMB(Int64(vs.internal_page_count) - Int64(vs.purgeable_count))
            wired = toMB(Int64(vs.wire_count))
            compressed = toMB(Int64(vs.compressor_page_count))
            cached = toMB(Int64(vs.external_page_count) + Int64(vs.purgeable_count))
            free = toMB(Int64(vs.free_count) - Int64(vs.speculative_count))
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let level = Int(sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        return MemoryTotals(
            totalMB: totalMB, usedMB: app + wired + compressed, appMB: app, wiredMB: wired,
            compressedMB: compressed, cachedMB: cached, freeMB: free,
            swapUsedMB: swapOK ? Int((Double(swap.xsu_used) / mb).rounded()) : 0,
            swapTotalMB: swapOK ? Int((Double(swap.xsu_total) / mb).rounded()) : 0,
            pressure: MemoryPressure(level: level))
    }

    private static func bootTime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        return TimeInterval(tv.tv_sec)
    }
}

/// sysctl по имени: целое. nil — такого параметра нет.
func sysctlInt(_ name: String) -> Int64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 8 else { return nil }
    var value: Int64 = 0
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    // Параметры бывают 4-байтовыми: старшие байты остались нулём, знак восстанавливаем сами.
    return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}
