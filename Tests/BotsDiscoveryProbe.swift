import Foundation

// Отдельная сборка поиска ботов: только BotsDiscovery.swift, без остального кода приложения.
// Так видно, что поиск ни от чего не зависит и ничего не пишет. Запуск: BotsDiscoveryProbe [--home <папка>]
// Без аргумента смотрит настоящий дом и настоящие процессы (только чтение) и печатает метку, имя и пояснение.
// С --home смотрит только эту папку и процессов не читает.
@main
enum Probe {
    static func main() {
        var roots = BotsDiscovery.live
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--home"), i + 1 < args.count {
            let home = args[i + 1]
            roots = BotsDiscovery.Roots(home: home, launchAgents: home + "/Library/LaunchAgents", uid: getuid(), processes: { [] })
        }
        let result = BotsDiscovery.scan(roots)
        print("найдено: \(result.candidates.count), пропущено: \(result.skipped)")
        for c in result.candidates {
            print("\(c.strength.rawValue)\t\(c.label ?? "процесс")\t\(c.name)\t\(c.why)")
        }
    }
}
