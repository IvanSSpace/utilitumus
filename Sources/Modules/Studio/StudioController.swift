import Combine
import Foundation

/// Модуль «Студия» в утилите: папка из настроек, сервер через `StudioRunner`, действия с экрана.
/// Токен Студии читает только `StudioRunner`, наружу отсюда уходит `StudioState`: адрес с одноразовым кодом, но не токен.
@MainActor
final class StudioController {
    let runner: StudioRunner
    private let defaults: UserDefaults
    private(set) var running = false

    init(runner: StudioRunner? = nil, defaults: UserDefaults = Kit.defaults) {
        self.defaults = defaults
        self.runner = runner ?? StudioRunner(folder: Self.storedFolder(defaults), launcher: StudioProcessLauncher(),
                                             network: StudioLiveNetwork(), system: StudioLiveSystem())
    }

    nonisolated static func storedFolder(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: StudioKeys.folder).flatMap(StudioPath.validated) ?? ""
    }

    var state: StudioState { runner.state }

    /// Включили. Папку читаем заново: пока утилита стояла, её мог менять центр.
    func start() {
        running = true
        runner.setFolder(Self.storedFolder(defaults))
        runner.start()
    }

    func stop() {
        running = false
        runner.stop()
    }

    /// Выход процесса: сервер должен уйти раньше нас.
    func stopAndWait() {
        running = false
        runner.stopAndWait()
    }

    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: StudioAction.self, limit: 2048, state: { state }) { perform($0) }
    }

    private func perform(_ action: StudioAction) -> String? {
        switch action {
        case .setFolder(let raw):
            guard let folder = StudioPath.validated(raw) else { return "Путь к папке должен быть абсолютным, без «.» и «..»" }
            if folder.isEmpty { defaults.removeObject(forKey: StudioKeys.folder) } else { defaults.set(folder, forKey: StudioKeys.folder) }
            runner.setFolder(folder)
            // Свой сервер из старой папки гасим, новая стартует, только если модуль включён.
            runner.stop()
            if running { runner.start() }
            return nil
        case .newLogin:
            guard running, runner.state.phase == .running else { return "Студия не запущена" }
            runner.newLogin()
            return nil
        }
    }

    /// Строка статуса: видна всем на этом Mac, поэтому ни пути, ни адреса в ней нет.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        switch runner.state.phase {
        case .stopped: return "остановлена"
        case .starting: return "запускается"
        case .running: return runner.state.ownsServer ? "работает" : "работает (запущена не здесь)"
        case .failed: return "ошибка"
        }
    }
}
