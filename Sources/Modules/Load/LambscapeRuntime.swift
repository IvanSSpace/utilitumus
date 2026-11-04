import Foundation
import Darwin

/// Что экран ошибки говорит человеку: что случилось, что сделать, куда нажать.
struct LambscapeProblem: Equatable, Sendable {
    struct Link: Equatable, Sendable {
        let title: String
        let url: URL
    }

    var title: String
    var message: String
    var steps: [String] = []
    var link: Link?
    /// Хвост лога сервера — показывается мелким шрифтом под советом.
    var logTail = ""

    static let pythonDownload = Link(title: "Скачать Python с python.org", url: URL(string: "https://www.python.org/downloads/macos/")!)
}

/// Итог проверки одного интерпретатора.
struct PythonProbe: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case ok
        case tooOld
        /// Версия подходит, но сервер не импортируется (битая сборка, нет модуля).
        case broken(String)
        case failedToRun(String)
        case timedOut
    }

    let path: String
    var version: String?
    var verdict: Verdict

    /// full — для отчёта (вся причина), иначе одна короткая строка для экрана.
    func summary(full: Bool = false) -> String {
        let v = version.map { "Python \($0)" } ?? "Python"
        switch verdict {
        case .ok: return "\(v) — подходит"
        case .tooOld: return "\(v) — слишком старый (нужен \(LambscapeRuntime.minimumPythonText)+)"
        case .broken(let why):
            let line = why.split(separator: "\n").first.map(String.init) ?? why
            return "\(v) — не запускает сервер: " + (full ? why : String(line.prefix(120)) + (line.count > 120 ? "…" : ""))
        case .failedToRun(let why): return "не запускается: \(why)"
        case .timedOut: return "\(v) — не ответил за \(Int(LambscapeRuntime.probeTimeout)) с"
        }
    }
}

/// Всё, что нужно до запуска сервера и может ждать диск, чужой процесс или
/// всплывающее окно macOS (доступ к «Документам»). Вызывать только с фонового
/// потока: `Process` с ожиданием на главном морозит окно, а там, где в
/// инициализатор синглтона вложен `waitUntilExit`, ещё и роняет приложение
/// («dispatch_once lock recursively», см. FanHelperInstaller).
enum LambscapeRuntime {
    /// Нижняя граница сервера: `tomllib` (3.11) и `X | None` в аннотациях.
    /// Проверено: 3.11 и 3.13 отдают снимок и историю; 3.9 падает на старте.
    static let minimumPython = (major: 3, minor: 11)
    static var minimumPythonText: String { "\(minimumPython.major).\(minimumPython.minor)" }

    /// Первый запуск Python на чужом маке: macOS сканирует бинарник (Gatekeeper,
    /// XProtect), на холодном диске это секунды. Зависший шим дольше не ждём.
    static let probeTimeout: TimeInterval = 30

    struct Plan: Sendable {
        let python: PythonProbe
        let src: URL
        let support: URL
        let logs: URL
        let roots: String
        let port: Int
        let portNote: String?
    }

    struct Prepared: Sendable {
        var probes: [PythonProbe]
        var plan: Plan?
        var problem: LambscapeProblem?
    }

    static func prepare(home: URL, preferredPort: Int, pythonOverride: String?) -> Prepared {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("lambscape/src"),
              FileManager.default.fileExists(atPath: src.appendingPathComponent("lambscape/server.py").path) else {
            return Prepared(probes: [], problem: LambscapeProblem(
                title: "В приложении нет модуля «Нагрузка»",
                message: "Папка lambscape не найдена внутри Utilitumus.app: установка повреждена или приложение собрано без неё.",
                steps: ["Переустановите Utilitumus: в Терминале выполните\ncurl -fsSL https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/install.sh | bash"]))
        }

        let support = home.appendingPathComponent("Library/Application Support/Utilitumus/lambscape")
        let logs = home.appendingPathComponent("Library/Logs/Utilitumus")
        for dir in [support, logs] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return Prepared(probes: [], problem: LambscapeProblem(
                    title: "Не удалось создать папку для данных",
                    message: "\(dir.path)\n\(error.localizedDescription)",
                    steps: ["Проверьте, что в домашней папке есть место и вы её владелец (Информация → Общий доступ и права).",
                            "Затем нажмите «Проверить снова»."]))
            }
        }

        let found = findPython(src: src, home: home, override: pythonOverride)
        guard let python = found.chosen else {
            return Prepared(probes: found.probes, problem: pythonProblem(found.probes))
        }
        let (port, note) = choosePort(preferred: preferredPort)
        return Prepared(probes: found.probes, plan: Plan(
            python: python, src: src, support: support, logs: logs,
            roots: projectRoots(home: home), port: port, portNote: note))
    }

    // MARK: Python

    static func standardCandidates(home: URL) -> [String] {
        let h = home.path
        var list: [String] = []
        // python.org
        for v in ["3.13", "3.14", "3.12", "3.11"] {
            list.append("/Library/Frameworks/Python.framework/Versions/\(v)/bin/python3")
        }
        list.append("/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
        // Homebrew: /opt/homebrew на Apple Silicon, /usr/local под Rosetta
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for name in ["python3.13", "python3.14", "python3.12", "python3.11", "python3"] {
                list.append("\(dir)/\(name)")
            }
        }
        // Менеджеры версий: у приложения из Dock нет их шимов в PATH
        for root in ["\(h)/.pyenv/versions", "\(h)/.asdf/installs/python",
                     "\(h)/.local/share/mise/installs/python", "\(h)/.local/share/uv/python"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                list.append("\(root)/\(name)/bin/python3")
            }
        }
        list.append("\(h)/.local/bin/python3")
        // Python из Command Line Tools — всегда 3.9: берём только чтобы в отчёте
        // было видно «есть лишь старый». /usr/bin/python3 не трогаем: без CLT это
        // заглушка, которая выскакивает окном установки.
        list.append("/Library/Developer/CommandLineTools/usr/bin/python3")
        return list
    }

    static func findPython(src: URL, home: URL, override: String?) -> (chosen: PythonProbe?, probes: [PythonProbe]) {
        var probes: [PythonProbe] = []
        var seen = Set<String>()
        var candidates = standardCandidates(home: home)
        if let override, !override.isEmpty { candidates.insert(override, at: 0) }
        for path in candidates {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else {
                if path == override {
                    probes.append(PythonProbe(path: path, version: nil, verdict: .failedToRun("файла нет или он не исполняемый (настройка lambscapePython)")))
                }
                continue
            }
            let probe = probe(path, src: src)
            probes.append(probe)
            if probe.verdict == .ok { return (probe, probes) }
        }
        return (nil, probes)
    }

    /// Запускает ровно то, что потом запустит сервер: `import lambscape.server`
    /// ловит и старую версию, и сломанную сборку (у Homebrew 3.14 на части
    /// систем не грузится pyexpat), которую одна проверка версии пропускает.
    static func probe(_ path: String, src: URL) -> PythonProbe {
        let code = """
        import sys
        print("%d.%d.%d" % sys.version_info[:3], flush=True)
        if sys.version_info < (\(minimumPython.major), \(minimumPython.minor)): sys.exit(10)
        import lambscape.server
        """
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = src.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let r = capture(path, ["-c", code], env: env, cwd: src, timeout: probeTimeout)
        let version = r.out.split(separator: "\n").first.map(String.init)
        if let error = r.launchError { return PythonProbe(path: path, version: nil, verdict: .failedToRun(error)) }
        if r.timedOut { return PythonProbe(path: path, version: version, verdict: .timedOut) }
        switch r.status {
        case 0: return PythonProbe(path: path, version: version, verdict: .ok)
        case 10: return PythonProbe(path: path, version: version, verdict: .tooOld)
        default: return PythonProbe(path: path, version: version, verdict: .broken(lastLines(r.err, 3)))
        }
    }

    static func pythonProblem(_ probes: [PythonProbe]) -> LambscapeProblem {
        let override = "defaults write local.utilitumus lambscapePython /путь/к/python3"
        guard !probes.isEmpty else {
            return LambscapeProblem(
                title: "Не найден Python",
                message: "Для модуля «Нагрузка» нужен Python \(minimumPythonText) или новее (лучше 3.13). На этом Mac подходящего нет.",
                steps: ["Скачайте установщик с python.org и поставьте с настройками по умолчанию.",
                        "Нажмите «Проверить снова».",
                        "Если Python уже стоит в необычном месте, укажите его в Терминале:\n\(override)"],
                link: LambscapeProblem.pythonDownload)
        }
        let list = probes.map { "• \($0.path)\n   \($0.summary())" }.joined(separator: "\n")
        var steps = ["Поставьте Python 3.13 с python.org: он не зависит от Homebrew и Command Line Tools.",
                     "Нажмите «Проверить снова»."]
        if let brew = probes.first(where: { $0.path.hasPrefix("/opt/homebrew") || $0.path.hasPrefix("/usr/local") }),
           case .broken = brew.verdict, let minor = brew.version?.split(separator: ".").prefix(2).joined(separator: ".") {
            steps.insert("Или почините Homebrew-вариант: brew reinstall python@\(minor), потом «Проверить снова».", at: 1)
        }
        steps.append("Если подходящий Python уже стоит в другом месте, укажите его:\n\(override)")
        return LambscapeProblem(
            title: "Найденный Python не подходит",
            message: "Нужен Python \(minimumPythonText) или новее, который запускает сервер панели. Что нашлось на этом Mac:\n\(list)",
            steps: steps, link: LambscapeProblem.pythonDownload)
    }

    // MARK: Порт

    /// Предпочтительный порт, а если его занял чужой процесс — первый свободный
    /// рядом: занятый порт иначе валил сервер с «Address already in use».
    static func choosePort(preferred: Int) -> (port: Int, note: String?) {
        if let port = bindable(preferred) { return (port, nil) }
        let owner = portOwner(preferred).map { " процессом \($0)" } ?? ""
        for candidate in Array((preferred + 1)...(preferred + 36)) + [0] {
            if let port = bindable(candidate) {
                return (port, "порт \(preferred) занят\(owner), панель работает на \(port)")
            }
        }
        return (preferred, "порт \(preferred) занят\(owner), свободный подобрать не удалось")
    }

    /// Так же, как сервер (SO_REUSEADDR): занят — nil. 0 — любой свободный.
    private static func bindable(_ port: Int) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { return nil }
        var actual = sockaddr_in()
        var length = size
        let got = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return got == 0 ? Int(UInt16(bigEndian: actual.sin_port)) : nil
    }

    private static func portOwner(_ port: Int) -> String? {
        let r = capture("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], env: [:], cwd: nil, timeout: 5)
        var pid: String?, name: String?
        for line in r.out.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), name == nil { name = String(line.dropFirst()) }
        }
        guard let name else { return nil }
        return "\(name) (pid \(pid ?? "?"))"
    }

    // MARK: Корни проектов и лог

    /// Корни проектов по умолчанию из lambscape плюс все ~/Documents/projects*:
    /// процесс, чей рабочий каталог внутри корня, попадает в группу проекта.
    /// Чтение ~/Documents на чистом маке вызывает системный запрос доступа и
    /// стоит, пока человек не ответит, — поэтому только в фоне.
    static func projectRoots(home: URL) -> String {
        var roots = ["~/Developer", "~/Projects", "~/projects", "~/code", "~/Documents/projects", "~/Documents/GitHub"]
        let documents = home.appendingPathComponent("Documents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        for name in names.sorted() where name.hasPrefix("projects") && name != "projects" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                roots.append("~/Documents/\(name)")
            }
        }
        return roots.joined(separator: ":")
    }

    /// Последние строки лога, не читая файл целиком (он только растёт).
    static func logTail(_ url: URL, lines: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count)
            .map { $0.count > 200 ? String($0.prefix(200)) + "…" : String($0) }.joined(separator: "\n")
    }

    // MARK: Process

    struct Captured: Sendable {
        var status: Int32 = -1
        var out = ""
        var err = ""
        var timedOut = false
        var launchError: String?
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    /// Запуск с ожиданием и тайм-аутом. stdin закрыт — иначе шим, ждущий ввода,
    /// висит вечно. Ждём семафором, а не `waitUntilExit`: тот крутит run loop.
    static func capture(_ path: String, _ args: [String], env: [String: String], cwd: URL?, timeout: TimeInterval) -> Captured {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return Captured(launchError: error.localizedDescription)
        }
        let out = Buffer(), err = Buffer()
        let readers = DispatchGroup()
        for (pipe, buffer) in [(outPipe, out), (errPipe, err)] {
            readers.enter()
            DispatchQueue.global().async {
                buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        var result = Captured()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        // Внук (например, sleep из шима) может держать конец пайпа — не ждём вечно.
        _ = readers.wait(timeout: .now() + 1)
        result.status = process.isRunning ? -1 : process.terminationStatus
        result.out = String(decoding: out.data, as: UTF8.self)
        result.err = String(decoding: err.data, as: UTF8.self)
        return result
    }
}
