import Foundation

/// Карточка «Диск»: износ SSD из smartctl (только если он установлен), запись на диск с загрузки из ioreg,
/// запись в своп с загрузки и за сутки, доля свопа во всей записи. Объёмы — в десятичных GB/TB,
/// как у производителя диска и в smartctl.
struct DiskCard: Sendable, Codable, Equatable {
    var model: String?
    var sizeGB: Int?
    var wearPct: Int?
    var writtenTB: Double?
    var sparePct: Int?
    var mediaErrors: Int?
    var swapWrittenGBSinceBoot: Double = 0
    var swapGBPerDay: Double
    var swapSharePct: Int?
    var swapWritten24hGB: Double?
    /// Меньше ~23 ч — число за сутки пересчитано, а не замерено; здесь часы, по которым считали.
    var swap24SpanHours: Double?
    /// smartctl установлен и вернул данные об износе.
    var hasSmart: Bool { wearPct != nil || writtenTB != nil || sparePct != nil }

    /// `swapWrittenGBSinceBoot` экран не показывает.
    private enum CodingKeys: String, CodingKey {
        case model, sizeGB, wearPct, writtenTB, sparePct, mediaErrors, swapGBPerDay, swapSharePct, swapWritten24hGB, swap24SpanHours
    }
}

/// Инструменты запускаются только в фоне и с кэшем: smartctl раз в час (`-a disk0`, таймаут 10 с,
/// только если установлен), ioreg раз в 10 минут. Замер их не ждёт.
final class DiskMonitor: @unchecked Sendable {
    static let smartEvery: TimeInterval = 3600
    static let ioregEvery: TimeInterval = 600
    private static let gb = 1e9

    /// Homebrew: /opt/homebrew на Apple Silicon, /usr/local на Intel.
    static let smartctlPath: String? = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Smart {
        var model: String?
        var wearPct: Int?
        var writtenTB: Double?
        var sparePct: Int?
        var mediaErrors: Int?
    }

    private struct IO {
        var writtenBytes: Int?
        var sizeGB: Int?
        var model: String?
    }

    private let lock = NSLock()
    private var smart = Smart()
    private var io = IO()
    private var smartAt = Date.distantPast
    private var ioAt = Date.distantPast
    private var running = false

    /// Карточка по кэшу; устаревшее обновляется в фоне.
    func card(swap24: (mb: Double, spanHours: Double)?) -> DiskCard {
        refreshIfStale()
        lock.lock()
        let smart = smart, io = io
        lock.unlock()
        let upDays = max(Date().timeIntervalSince1970 - SystemMemory.host.bootTime, 1) / 86400
        let swapGB = Double(SystemMemory.swapoutsMB()) * 1_048_576 / Self.gb
        let writesGB = io.writtenBytes.map { Double($0) / Self.gb }
        return DiskCard(
            model: smart.model ?? io.model, sizeGB: io.sizeGB, wearPct: smart.wearPct, writtenTB: smart.writtenTB,
            sparePct: smart.sparePct, mediaErrors: smart.mediaErrors,
            swapWrittenGBSinceBoot: (swapGB * 10).rounded() / 10, swapGBPerDay: (swapGB / upDays * 10).rounded() / 10,
            swapSharePct: writesGB.flatMap { $0 > 0 ? Int((100 * swapGB / $0).rounded()) : nil },
            swapWritten24hGB: swap24.map { ($0.mb * 1_048_576 / Self.gb * 10).rounded() / 10 },
            swap24SpanHours: swap24.map { ($0.spanHours * 10).rounded() / 10 })
    }

    private func refreshIfStale() {
        lock.lock()
        let now = Date()
        let needSmart = Self.smartctlPath != nil && now.timeIntervalSince(smartAt) >= Self.smartEvery
        let needIO = now.timeIntervalSince(ioAt) >= Self.ioregEvery
        let start = (needSmart || needIO) && !running
        if start { running = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            var newSmart: Smart?, newIO: IO?
            if needSmart, let path = Self.smartctlPath {
                newSmart = Self.parseSmart(Tool.run(path, ["-a", "disk0"], timeout: 10) ?? "")
            }
            if needIO {
                newIO = Self.parseIORegistry(Tool.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOBlockStorageDriver", "-d", "2", "-l"], timeout: 10) ?? "")
            }
            lock.lock()
            if let newSmart { smart = newSmart; smartAt = Date() }
            if let newIO { io = newIO; ioAt = Date() }
            running = false
            lock.unlock()
        }
    }

    private static func parseSmart(_ text: String) -> Smart {
        func capture(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        func number(_ s: String?) -> Int? { s.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }
        var out = Smart()
        out.model = capture(#"^(?:Model Number|Device Model):\s*(\S.*?)\s*$"#)
        out.wearPct = number(capture(#"^Percentage Used:\s*(\d+)%"#))
        // NVMe: Data Unit — 1000 блоков по 512 байт.
        out.writtenTB = number(capture(#"^Data Units Written:\s*([\d,]+)"#)).map { (Double($0) * 512_000 / 1e12 * 10).rounded() / 10 }
        out.sparePct = number(capture(#"^Available Spare:\s*(\d+)%"#))
        out.mediaErrors = number(capture(#"^Media and Data Integrity Errors:\s*([\d,]+)"#))
        return out
    }

    /// `ioreg -a -r -c IOBlockStorageDriver -d 2 -l`: у драйвера внутреннего диска (его носитель — disk0) берём
    /// «Bytes (Write)» с загрузки, у носителя — размер и имя модели.
    private static func parseIORegistry(_ text: String) -> IO {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let drivers = plist as? [[String: Any]] else { return IO() }
        for drv in drivers {
            for media in drv["IORegistryEntryChildren"] as? [[String: Any]] ?? [] where media["BSD Name"] as? String == "disk0" {
                var out = IO()
                let stats = drv["Statistics"] as? [String: Any]
                out.writtenBytes = (stats?["Bytes (Write)"] as? NSNumber)?.intValue
                if let size = (media["Size"] as? NSNumber)?.doubleValue, size > 0 { out.sizeGB = Int((size / gb).rounded()) }
                if let name = media["IORegistryEntryName"] as? String {
                    out.model = name.hasSuffix(" Media") ? String(name.dropLast(6)) : name
                }
                return out
            }
        }
        return IO()
    }
}
