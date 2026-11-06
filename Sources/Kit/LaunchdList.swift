import Foundation

/// Разбор `launchctl list`: метка → pid (nil — загружен, но не запущен).
enum LaunchdList {
    static func parse(_ text: String) -> [String: Int32?] {
        var out: [String: Int32?] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            if let pid = Int32(parts[0]) { out[String(parts[2])] = .some(pid) }
            else if parts[0] == "-" { out[String(parts[2])] = .some(nil) }
        }
        return out
    }
}
