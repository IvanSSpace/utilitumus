import Foundation

// Отдельная сборка поиска ботов: только BotsDiscovery.swift, без остального кода приложения.
// Так видно, что поиск ни от чего не зависит и ничего не пишет. Запуск: BotsDiscoveryProbe --home <папка>
// Смотрит только эту папку и процессов не читает: настоящий дом тестам запрещён.
@main
enum Probe {
    static func main() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--home"), i + 1 < args.count else {
            print("нужно: --home <папка>")
            exit(2)
        }
        let home = args[i + 1]
        let roots = BotsDiscovery.Roots(home: home, launchAgents: home + "/Library/LaunchAgents", uid: getuid(), processes: { [] })
        let result = BotsDiscovery.scan(roots)
        print("найдено: \(result.candidates.count), пропущено: \(result.skipped)")
        for c in result.candidates {
            print("\(c.strength.rawValue)\t\(c.label ?? "процесс")\t\(c.name)\t\(c.why)")
        }
    }
}
