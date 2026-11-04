import SwiftUI
import WebKit

/// Модуль «Нагрузка» — публичный lambscape (github.com/IvanSSpace/lambscape),
/// встроенный в приложение: исходники лежат в Contents/Resources/lambscape
/// (снимок из Vendor/, обновляется scripts/update-lambscape.sh), сервер
/// Utilitumus запускает сам и гасит при выходе.
///
/// Свой порт и свои папки данных/логов — чтобы не пересекаться с отдельно
/// установленным lambscape (тот по умолчанию на 5262 со своим launchd-агентом).
///
/// Любая неудача кончается экраном с причиной и советом, а не вечным «Запускаю»:
/// тяжёлое (поиск Python, порт, папки) — в `LambscapeRuntime` и в фоне.
@MainActor
final class LambscapePanel: ObservableObject {
    static let shared = LambscapePanel()

    nonisolated static let preferredPort = 5263

    enum State: Equatable {
        case starting(String)
        case running
        case failed(LambscapeProblem)
    }

    @Published private(set) var state: State = .starting("Запускаю панель…")

    /// Порт может уйти от предпочтительного, если его занял чужой процесс.
    private(set) var port = preferredPort
    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Один веб-вид на всё время жизни приложения: переключился на другой модуль
    /// и обратно — страница не перезагружается и не теряет раскрытые группы.
    let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(LambscapeTheme.userScript)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }()

    /// Сколько ждём ответа от живого сервера, прежде чем показать ошибку. 10 с
    /// не хватало: тёплый старт — 0,3–0,6 с, но на чужом маке первый запуск
    /// Python проверяют Gatekeeper и XProtect. Компиляция .py (без кэша
    /// байт-кода) — доли секунды, дело не в ней. Ждать дальше смысла нет: за
    /// минуту живой сервер не ответил — виновата сеть/прокси, а не медленный диск.
    private static let startTimeout: TimeInterval = 60

    private var process: Process?
    private var startTask: Task<Void, Never>?
    private var report = Report()
    private let navigationWatcher = NavigationWatcher()

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let logURL = home.appendingPathComponent("Library/Logs/Utilitumus/lambscape.log")

    /// То, что попадёт в «Скопировать диагностику».
    private struct Report {
        var probes: [PythonProbe] = []
        var python: PythonProbe?
        var portNote: String?
        var exit: String?
        var note: String?
    }

    private init() {
        webView.navigationDelegate = navigationWatcher
        navigationWatcher.onFailure = { [weak self] error in self?.pageFailed(error) }
    }

    func start() {
        // Сервер уже запущен — второй не нужен (модуль могли включить повторно).
        // Незавершённый запуск или ошибка — начинаем заново: так работает «Проверить снова».
        guard process == nil else { return }
        startTask?.cancel()
        report = Report()
        state = .starting("Запускаю панель…")
        startTask = Task { await bringUp() }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        let running = process
        process = nil
        running?.terminate()
    }

    func restart() {
        stop()
        start()
    }

    func reload() {
        webView.load(URLRequest(url: url))
    }

    private func becameRunning() {
        state = .running
        // Новый сервер выдаёт новый токен: страница старого не сможет нажимать кнопки.
        reload()
    }

    private func bringUp() async {
        // Сервер уже отвечает — например, остался от упавшего прошлого запуска.
        if await Self.isLambscape(port: Self.preferredPort) {
            port = Self.preferredPort
            report.note = "использован уже работавший сервер на порту \(port)"
            becameRunning()
            return
        }
        guard !Task.isCancelled else { return }

        state = .starting("Ищу Python…")
        let home = Self.home
        let override = UserDefaults.standard.string(forKey: "lambscapePython")
        let prepared = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: LambscapeRuntime.prepare(home: home, preferredPort: Self.preferredPort, pythonOverride: override))
            }
        }
        guard !Task.isCancelled else { return }
        report.probes = prepared.probes
        guard let plan = prepared.plan else {
            state = .failed(prepared.problem ?? LambscapeProblem(title: "Панель не запустилась", message: "Неизвестная причина."))
            return
        }
        report.python = plan.python
        report.portNote = plan.portNote
        port = plan.port

        state = .starting("Запускаю сервер…")
        let proc: Process
        do {
            proc = try launch(plan)
        } catch {
            state = .failed(LambscapeProblem(
                title: "Не удалось запустить Python",
                message: "\(plan.python.path)\n\(error.localizedDescription)",
                steps: ["Если Python из Homebrew или менеджера версий, переустановите его или поставьте Python с python.org."],
                link: LambscapeProblem.pythonDownload))
            return
        }

        let began = Date()
        var slow = false, gaveUp = false
        // Ждём, пока процесс жив: упал — об этом скажет terminationHandler.
        while !Task.isCancelled, process === proc {
            if await Self.isLambscape(port: port) {
                becameRunning()
                return
            }
            let elapsed = Date().timeIntervalSince(began)
            if elapsed > 10, !slow, !gaveUp {
                slow = true
                state = .starting("Запускаю сервер… Дольше обычного: macOS проверяет Python при первом запуске.")
            }
            if elapsed > Self.startTimeout, !gaveUp {
                gaveUp = true
                state = .failed(Self.noResponseProblem(port: port, tail: LambscapeRuntime.logTail(Self.logURL, lines: 8)))
            }
            // После «сдался» опрашиваем реже, но продолжаем: ответит — сами оживём.
            try? await Task.sleep(for: .milliseconds(gaveUp ? 2000 : 250))
        }
    }

    private func launch(_ plan: LambscapeRuntime.Plan) throws -> Process {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: Self.logURL)
        log.seekToEndOfFile()
        // Метка начала запуска: в хвосте лога сразу видно, где свежая попытка.
        log.write(Data("=== \(Date()) Utilitumus запускает \(plan.python.path) на порту \(plan.port) ===\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.python.path)
        process.arguments = ["-m", "lambscape.server"]
        process.currentDirectoryURL = plan.src
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = plan.src.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["LAMBSCAPE_PORT"] = String(plan.port)
        env["LAMBSCAPE_HOME"] = plan.support.path
        env["LAMBSCAPE_LOGS"] = plan.logs.appendingPathComponent("lambscape").path
        env["LAMBSCAPE_ROOTS"] = plan.roots
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { proc in
            let status = proc.terminationStatus, reason = proc.terminationReason
            Task { @MainActor in LambscapePanel.shared.serverExited(proc, status: status, reason: reason) }
        }
        try process.run()
        self.process = process
        return process
    }

    private func serverExited(_ proc: Process, status: Int32, reason: Process.TerminationReason) {
        // Не мы погасили (stop() обнуляет process) — показать причину.
        guard process === proc else { return }
        process = nil
        let exit = reason == .uncaughtSignal ? "убит сигналом \(status)" : "код выхода \(status)"
        report.exit = exit
        state = .failed(Self.exitProblem(exit: exit, tail: LambscapeRuntime.logTail(Self.logURL, lines: 8), port: port))
    }

    private func pageFailed(_ error: Error) {
        guard state == .running else { return }
        report.note = "страница не загрузилась: \(error.localizedDescription)"
        state = .failed(LambscapeProblem(
            title: "Страница панели не открылась",
            message: "Сервер отвечает, но окно приложения не смогло загрузить \(url.absoluteString):\n\(error.localizedDescription)",
            steps: ["Если включены прокси, VPN или файрвол, добавьте 127.0.0.1 в исключения.",
                    "Откройте панель в браузере: если там работает, пришлите диагностику."],
            link: LambscapeProblem.Link(title: "Открыть в браузере", url: url)))
    }

    private static func noResponseProblem(port: Int, tail: String) -> LambscapeProblem {
        LambscapeProblem(
            title: "Сервер запущен, но не отвечает",
            message: "Прошло \(Int(startTimeout)) с, а 127.0.0.1:\(port) молчит, хотя процесс жив.",
            steps: ["Подождите ещё немного: экран исчезнет сам, когда сервер ответит.",
                    "Если включены прокси, VPN или файрвол, добавьте 127.0.0.1 в исключения.",
                    "Не помогло — «Проверить снова», затем «Скопировать диагностику»."],
            logTail: tail)
    }

    private static func exitProblem(exit: String, tail: String, port: Int) -> LambscapeProblem {
        var problem = LambscapeProblem(title: "Сервер панели остановился", message: "Процесс lambscape завершился: \(exit).", logTail: tail)
        if tail.contains("Address already in use") {
            problem.title = "Порт \(port) занят"
            problem.message = "Другая программа заняла порт сервера панели (\(exit))."
            problem.steps = ["Нажмите «Проверить снова»: приложение возьмёт другой свободный порт."]
        } else if tail.contains("ImportError") || tail.contains("ModuleNotFoundError") || tail.contains("dlopen") {
            problem.title = "Python не смог загрузить сервер"
            problem.message = "Python запустился, но не открыл свою библиотеку (\(exit)). Обычно это битая сборка Python."
            problem.steps = ["Поставьте Python 3.13 с python.org и нажмите «Проверить снова»."]
            problem.link = LambscapeProblem.pythonDownload
        } else if tail.contains("Operation not permitted") || tail.contains("Permission denied") {
            problem.title = "Нет прав на файл или папку"
            problem.steps = ["Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску: включите Utilitumus, перезапустите приложение."]
        } else {
            problem.steps = ["Нажмите «Проверить снова». Если повторится, «Скопировать диагностику» и отправьте тому, кто дал приложение."]
        }
        return problem
    }

    /// Свой запрос в обход системного прокси (иначе localhost мог уйти в него) и
    /// проверка, что отвечает именно lambscape: чужой сервер на порту раньше
    /// принимался за наш, и в окне открывалась чужая страница.
    private static func isLambscape(port: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/"),
              let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return http.value(forHTTPHeaderField: "Server")?.hasPrefix("lambscape") == true
    }

    // MARK: Диагностика

    func diagnosticsText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = [
            "Utilitumus \(version), модуль «Нагрузка»",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString) (\(arch))",
            "Приложение: \(Bundle.main.bundlePath)",
            "Состояние: \(stateText)",
        ]
        if let python = report.python {
            lines.append("Python (выбран): \(python.path), версия \(python.version ?? "?")")
        }
        if let override = UserDefaults.standard.string(forKey: "lambscapePython") {
            lines.append("Настройка lambscapePython: \(override)")
        }
        if !report.probes.isEmpty {
            lines.append("Проверенные интерпретаторы:")
            lines += report.probes.map { "  \($0.path): \($0.summary(full: true).replacingOccurrences(of: "\n", with: " | "))" }
        }
        lines.append("Порт: \(port)" + (report.portNote.map { " (\($0))" } ?? ""))
        if let note = report.note { lines.append("Примечание: \(note)") }
        lines.append("Процесс сервера: " + (process.map { "работает, pid \($0.processIdentifier)" } ?? (report.exit ?? "не запущен")))
        lines.append("Лог \(Self.logURL.path), последние строки:")
        lines.append(LambscapeRuntime.logTail(Self.logURL, lines: 40))
        return lines.joined(separator: "\n")
    }

    private var stateText: String {
        switch state {
        case .starting(let phase): return "запуск (\(phase))"
        case .running: return "работает"
        case .failed(let problem): return "ошибка: \(problem.title)"
        }
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
    }
}

/// Сообщает о неудачной загрузке страницы: иначе вместо панели оставался пустой
/// прозрачный вид без единого слова. Отмены (-999, 102) — это перезагрузка поверх
/// загрузки, не ошибка.
@MainActor
private final class NavigationWatcher: NSObject, WKNavigationDelegate {
    var onFailure: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        onFailure?(error)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct LoadView: View {
    @ObservedObject var panel = LambscapePanel.shared
    @State private var copied = false

    var body: some View {
        Group {
            switch panel.state {
            case .running:
                WebViewHost(webView: panel.webView)
            case .starting(let phase):
                ProgressView(phase)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let problem):
                failure(problem)
            }
        }
        .navigationTitle("Нагрузка")
        .navigationSubtitle("Память, сессии, фоновые агенты")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    panel.state == .running ? panel.reload() : panel.restart()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .help("Обновить")

                Button {
                    NSWorkspace.shared.open(panel.url)
                } label: {
                    Label("Открыть в браузере", systemImage: "safari")
                }
                .help("Открыть в браузере")
                .disabled(panel.state != .running)
            }
        }
    }

    private func failure(_ problem: LambscapeProblem) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(problem.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(problem.message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !problem.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Что сделать").font(.headline)
                        ForEach(Array(problem.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !problem.logTail.isEmpty {
                    Text(problem.logTail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    if let link = problem.link {
                        Link(link.title, destination: link.url)
                    }
                    Button("Проверить снова") { panel.restart() }
                        .buttonStyle(.borderedProminent)
                    Button(copied ? "Скопировано" : "Скопировать диагностику") {
                        panel.copyDiagnostics()
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
