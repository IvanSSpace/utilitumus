import Foundation

/// Форматирование чисел для экрана «Нагрузка»: те же правила, что в lambscape,
/// чтобы цифры на экране читались так же, как в веб-версии.
enum Fmt {
    /// Целое число GB без хвоста, иначе один знак: «16», «9.6».
    static func gb(_ mb: Double) -> String {
        mb.truncatingRemainder(dividingBy: 1024) == 0 ? String(Int(mb / 1024)) : String(format: "%.1f", mb / 1024)
    }

    /// «512 MB» до гигабайта, дальше «1.5 GB».
    static func mb(_ v: Double) -> String {
        v < 1024 ? "\(Int(v.rounded())) MB" : gb(v) + " GB"
    }

    static func mb(_ v: Int) -> String { mb(Double(v)) }

    /// Процент от целого: «70%».
    static func percent(_ a: Double, of b: Double) -> String {
        b > 0 ? "\(Int((a / b * 100).rounded()))%" : "—"
    }

    /// «3 · 9.6 · 108»: один знак только у малых чисел.
    static func compact(_ x: Double) -> String {
        x >= 10 ? String(Int(x.rounded())) : String(format: "%g", (x * 10).rounded() / 10)
    }

    /// Русское склонение с числом: `plural(5, "процесс", "процесса", "процессов")` → «5 процессов».
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(word(n, one, few, many))"
    }

    /// То же без числа.
    static func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = n % 10, b = n % 100
        return a == 1 && b != 11 ? one : (2...4).contains(a) && !(12...14).contains(b) ? few : many
    }

    /// Сколько прошло: «меньше минуты», «15 мин», «3 ч», «2 д».
    static func age(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "меньше минуты" }
        if s < 3600 { return "\(s / 60) мин" }
        if s < 2 * 86400 { return "\(s / 3600) ч" }
        return "\(s / 86400) д"
    }

    /// Аптайм/интервал: «5 мин», «3.5 ч», «12 д».
    static func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded())) с" }
        if s < 3600 { return "\(Int((s / 60).rounded())) мин" }
        if s < 36000 { return String(format: "%g", (s / 360).rounded() / 10) + " ч" }
        if s < 172_800 { return "\(Int((s / 3600).rounded())) ч" }
        return "\(Int((s / 86400).rounded())) д"
    }
}
