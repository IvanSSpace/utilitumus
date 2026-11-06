import Foundation

/// Вид потомка: по нему решаем, что считать dev-сервером, сборкой и что показывать подписью.
enum ProcessKind: String, Sendable {
    case shell, mcp, devServer, build, other
}

/// Классификация процессов: приложения, шеллы, dev-серверы, Claude. Правила один в один с lambscape
/// (attrib.py, procs.py, sessions.py), чтобы группы и подсказки совпадали с веб-версией.
enum Kinds {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"]
    static let interpreters: Set<String> = ["node", "bun", "deno", "uv", "uvx", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node"]

    /// Служебные .app, которые на деле часть другого приложения.
    private static let appOf = ["Orca Terminal Host": "Orca"]
    private static let short = ["Google Chrome": "Chrome", "Google Chrome Beta": "Chrome Beta",
                                "Google Chrome Canary": "Chrome Canary", "Microsoft Edge": "Edge", "Brave Browser": "Brave"]
    static let browsers: Set<String> = ["Arc", "Chrome", "Chrome Beta", "Chrome Canary", "Chromium", "Edge", "Brave",
                                        "Opera", "Vivaldi", "Yandex", "Dia", "Comet"]
    private static let helperTypes = ["gpu-process": "GPU", "crashpad-handler": "отчёты о сбоях", "ppapi": "плагин", "plugin": "плагин"]
    private static let utilityTypes = ["network": "сеть", "audio": "звук", "storage": "хранилище", "video_capture": "камера"]

    private static let devPattern = try! NSRegularExpression(
        pattern: #"\b(webpack|vite|next|tsx|nodemon|uvicorn)\b|(?<![a-z])serve|start:dev"#, options: [.caseInsensitive])
    private static let secretPattern = try! NSRegularExpression(
        pattern: "token|secret|passw|api[-_]?key|auth|bearer|cookie|credential", options: [.caseInsensitive])
    private static let randomPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9+_=:.-]{32,}$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Приложения и пути

    /// Внешний .app, которому принадлежит exe (хелперы и рендереры — тоже). Python.app внутри фреймворка — не приложение.
    static func appName(of exe: String) -> String? {
        guard exe.contains(".app/") else { return nil }
        // Первый компонент пути вида «X.app», за которым ещё что-то есть: так же, как /([^/]+)\.app/.
        let parts = exe.split(separator: "/", omittingEmptySubsequences: false)
        var offset = 0
        for (i, part) in parts.enumerated() {
            if i < parts.count - 1, part.hasSuffix(".app"), part.count > 4 {
                let before = exe.prefix(offset)
                if before.contains(".framework/") { return nil }
                let name = String(part.dropLast(4))
                return appOf[name] ?? name
            }
            offset += part.count + 1
        }
        return nil
    }

    static func shortAppName(_ name: String) -> String { short[name] ?? name }

    static func isSystemPath(_ exe: String) -> Bool {
        let prefixes = ["/System/Library/", "/System/Cryptexes/", "/System/Volumes/Preboot/Cryptexes/OS/",
                        "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
        return prefixes.contains { exe.hasPrefix($0) } && !exe.hasPrefix("/usr/local/")
    }

    /// Хост вкладок терминала: шеллы под ним — вкладки, а атрибуцию от него не наследуем.
    static func terminalApp(_ p: LoadProcess) -> String? { p.terminal }

    /// По пути, а не по имени: имя берётся из argv[0], а его задаёт сам процесс.
    static func terminalApp(exe: String) -> String? {
        let file = exe.split(separator: "/").last ?? ""
        if file == "orca-terminal-host", exe.contains("/Orca Terminal Host.app/Contents/") || exe.contains("/Orca.app/Contents/") {
            return "Orca"
        }
        if exe.hasSuffix("/iTerm.app/Contents/MacOS/iTerm2") { return "iTerm2" }
        // Новые версии копируют сервер в Application Support.
        if file.hasPrefix("iTermServer"), exe.contains("/Library/Application Support/iTerm2/") || exe.contains("/iTerm.app/Contents/") {
            return "iTerm2"
        }
        if exe.hasSuffix("/Terminal.app/Contents/MacOS/Terminal") { return "Terminal" }
        return nil
    }

    /// Файл на защищённом томе системы. /usr/local — это Homebrew, а через /System/Volumes/Data
    /// можно запустить любой файл пользователя, и путь процесса будет начинаться с /System/.
    static func isOSExecutable(_ exe: String) -> Bool {
        (exe.hasPrefix("/System/") && !exe.hasPrefix("/System/Volumes/Data/")) || (exe.hasPrefix("/usr/") && !exe.hasPrefix("/usr/local/"))
    }

    // MARK: Claude

    private static func claudeExecutable(exe: String, exeName: String, name: String) -> Bool {
        exe.contains("/.local/share/claude/versions/") || exeName.hasPrefix("claude")
            || exe.contains("/claude-code/") || name == "claude"
    }

    /// Одноразовый `claude -p` (боты, скрипты): не сессия.
    static func isPrint(_ p: LoadProcess) -> Bool {
        (p.args.contains("-p") || p.args.contains("--print")) && claudeExecutable(exe: p.exe, exeName: p.exeName, name: p.name)
    }

    /// Сессия Claude Code — это процесс claude без `-p`. Разбор сессий (имя, статус, транскрипт) — этап 2.
    static func isClaude(_ p: LoadProcess) -> Bool { p.isClaude }

    static func isClaudeSession(exe: String, exeName: String, name: String, args: [String]) -> Bool {
        claudeExecutable(exe: exe, exeName: exeName, name: name) && !(args.contains("-p") || args.contains("--print"))
    }

    /// Приложение, которое ведёт сессию: Claude.app, IDE. Такую сессию останавливает само приложение.
    /// Шелл и хост терминала хозяином не считаются: сессия во вкладке терминала — своя.
    static func hostApp(of p: LoadProcess, procs: [Int32: LoadProcess]) -> String? {
        if let parent = procs[p.ppid], terminalApp(parent) == nil, let app = appName(of: parent.exe) { return app }
        return appName(of: p.exe)
    }

    // MARK: Потомки

    /// Компиляторы и сборщики: по имени исполняемого файла, а не по аргументам — иначе `swift-frontend …/serve/…`
    /// принимался за dev-сервер.
    static let buildTools: Set<String> = ["swift-frontend", "swift-driver", "swift-build", "swift-autolink-extract", "swiftc",
                                          "clang", "clang++", "clang-cache", "cc", "c++", "gcc", "g++", "ld", "lld", "rustc", "cargo",
                                          "tsc", "esbuild", "swc", "xcodebuild", "ninja", "make", "cmake"]

    static func isBuildTool(_ p: LoadProcess) -> Bool {
        buildTools.contains(p.name) || buildTools.contains(p.exeName)
    }

    static func childKind(_ p: LoadProcess) -> ProcessKind {
        if shells.contains(p.name) { return .shell }
        if isBuildTool(p) { return .build }
        let text = p.args.isEmpty ? p.exe : p.args.joined(separator: " ")
        if text.range(of: "mcp", options: .caseInsensitive) != nil { return .mcp }
        if matches(devPattern, text) { return .devServer }
        return .other
    }

    // MARK: Подписи

    /// «Arc · вкладка», «Chrome · GPU»: хелпер браузера или Electron. Он всегда внутри .app —
    /// так «webpack --type=prod» из проекта не примем за хелпер.
    private static func helperLabel(_ p: LoadProcess) -> String? {
        guard let kind = p.args.dropFirst().first(where: { $0.hasPrefix("--type=") }).map({ String($0.dropFirst(7)) }),
              let raw = appName(of: p.exe) else { return nil }
        let app = shortAppName(raw)
        let what: String
        switch kind {
        case "renderer":
            what = p.args.contains("--extension-process") ? "расширение" : browsers.contains(app) ? "вкладка" : "окно"
        case "utility":
            let sub = p.args.first { $0.hasPrefix("--utility-sub-type=") }.map { String($0.dropFirst(19)) } ?? ""
            what = utilityTypes[String(sub.split(separator: ".", maxSplits: 1).first ?? "")] ?? "служба"
        default:
            what = helperTypes[kind] ?? "служба"
        }
        return "\(app) · \(what)"
    }

    /// Короткая подпись процесса для UI: имя и значимые аргументы. Секреты не показываем,
    /// хелперы браузеров подписываем по-человечески.
    static func label(_ p: LoadProcess, width: Int = 60) -> String {
        if let helper = helperLabel(p) { return String(helper.prefix(width)) }
        var parts = [p.name]
        var skip = false
        for a in p.args.dropFirst() {
            if skip { skip = false; continue }
            if matches(secretPattern, a) {
                skip = a.hasPrefix("-") && !a.contains("=") // «--token VALUE»: значение — следующий аргумент
                continue
            }
            if a.isEmpty || matches(randomPattern, a) { continue }
            parts.append(a.hasPrefix("/") ? a.split(separator: "/", omittingEmptySubsequences: false).suffix(3).joined(separator: "/") : a)
            if parts.reduce(0, { $0 + $1.count }) >= width { break }
        }
        return String(parts.joined(separator: " ").prefix(width))
    }
}
