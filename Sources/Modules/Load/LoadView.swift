import SwiftUI
import WebKit

/// Модуль «Нагрузка» — публичный lambscape (github.com/IvanSSpace/lambscape),
/// встроенный в приложение: исходники лежат в Contents/Resources/lambscape
/// (снимок из Vendor/, обновляется scripts/update-lambscape.sh), сервер
/// Utilitumus запускает сам и гасит при выходе.
///
/// Свой порт и свои папки данных/логов — чтобы не пересекаться с отдельно
/// установленным lambscape (тот по умолчанию на 5262 со своим launchd-агентом).
@MainActor
final class LambscapePanel: ObservableObject {
    static let shared = LambscapePanel()

    static let port = 5263
    static let url = URL(string: "http://127.0.0.1:\(port)/")!

    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .starting

    /// Один веб-вид на всё время жизни приложения: переключился на другой модуль
    /// и обратно — страница не перезагружается и не теряет раскрытые группы.
    let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(LambscapeTheme.userScript)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }()

    private var process: Process?

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let logURL = home.appendingPathComponent("Library/Logs/Utilitumus/lambscape.log")

    private init() {}

    func start() {
        state = .starting
        Task {
            // Сервер уже отвечает — например, остался от упавшего прошлого запуска.
            if await Self.isAlive() {
                becameRunning()
                return
            }
            do {
                try launch()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if process?.isRunning == false { break }
                if await Self.isAlive() {
                    becameRunning()
                    return
                }
            }
            state = .failed("Сервер не запустился. Последние строки лога:\n" + Self.logTail())
        }
    }

    func stop() {
        let running = process
        process = nil
        running?.terminate()
    }

    func restart() {
        stop()
        start()
    }

    func reload() {
        webView.load(URLRequest(url: Self.url))
    }

    private func becameRunning() {
        state = .running
        if webView.url == nil { reload() }
    }

    private func launch() throws {
        guard let python = Self.findPython() else {
            throw LaunchError("Для панели нагрузки нужен Python 3.13 или новее: python.org или `brew install python@3.13`.")
        }
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("lambscape/src"),
              FileManager.default.fileExists(atPath: src.path) else {
            throw LaunchError("В приложении нет lambscape — пересобери его через build.sh.")
        }

        let fm = FileManager.default
        let support = Self.home.appendingPathComponent("Library/Application Support/Utilitumus/lambscape")
        let logs = Self.logURL.deletingLastPathComponent()
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: Self.logURL)
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "lambscape.server"]
        process.currentDirectoryURL = src
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = src.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["LAMBSCAPE_PORT"] = String(Self.port)
        env["LAMBSCAPE_HOME"] = support.path
        env["LAMBSCAPE_LOGS"] = logs.appendingPathComponent("lambscape").path
        env["LAMBSCAPE_ROOTS"] = Self.projectRoots()
        process.environment = env
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { proc in
            Task { @MainActor in
                let panel = LambscapePanel.shared
                // Упал сам (а не мы погасили) — показать причину.
                if panel.process === proc {
                    panel.process = nil
                    panel.state = .failed("Сервер остановился (код \(proc.terminationStatus)). Последние строки лога:\n" + Self.logTail())
                }
            }
        }
        try process.run()
        self.process = process
    }

    /// Корни проектов по умолчанию из lambscape плюс все ~/Documents/projects*:
    /// процесс, чей рабочий каталог внутри корня, попадает в группу проекта.
    private static func projectRoots() -> String {
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

    /// Тот же порядок поиска, что у `bin/lambscape`. /usr/bin/python3 пропускаем:
    /// без Command Line Tools это заглушка, которая покажет окно установки.
    private static func findPython() -> String? {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13", "/usr/local/bin/python3",
        ]
        return candidates.first { path in
            guard FileManager.default.isExecutableFile(atPath: path) else { return false }
            let check = Process()
            check.executableURL = URL(fileURLWithPath: path)
            check.arguments = ["-c", "import sys; sys.exit(sys.version_info < (3, 13))"]
            guard (try? check.run()) != nil else { return false }
            check.waitUntilExit()
            return check.terminationStatus == 0
        }
    }

    private static func isAlive() async -> Bool {
        let request = URLRequest(url: url, timeoutInterval: 1)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func logTail() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(5).joined(separator: "\n")
    }

    private struct LaunchError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct LoadView: View {
    @ObservedObject var panel = LambscapePanel.shared

    var body: some View {
        Group {
            switch panel.state {
            case .running:
                WebViewHost(webView: panel.webView)
            case .starting:
                ProgressView("Запускаю панель…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Панель нагрузки не запустилась", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } actions: {
                    Button("Перезапустить") { panel.restart() }
                        .buttonStyle(.borderedProminent)
                }
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
                    NSWorkspace.shared.open(LambscapePanel.url)
                } label: {
                    Label("Открыть в браузере", systemImage: "safari")
                }
                .help("Открыть в браузере")
                .disabled(panel.state != .running)
            }
        }
    }
}
