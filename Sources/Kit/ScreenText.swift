import Foundation

/// Отдельный файл без зависимостей: поиск ботов собирается один, без остального кода (Tests/run-bots-remote-check.sh).
enum ScreenText {
    /// Строка для экрана: без управляющих и невидимых символов, не длиннее `limit`.
    static func clean(_ s: String, _ limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v < 0x20 || (0x7f...0x9f).contains(v) || v == 0x2028 || v == 0x2029 || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200b || v == 0xfeff || v == 0x061c || v == 0x200e || v == 0x200f {
                out.append(" ")
            } else {
                out.append(u)
            }
        }
        let text = String(out).trimmingCharacters(in: .whitespaces)
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
