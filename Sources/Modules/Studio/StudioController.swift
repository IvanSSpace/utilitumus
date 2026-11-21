import Combine
import Foundation

/// Модуль «Студия» в утилите: папка из настроек, сервер через `StudioRunner`, действия с экрана.
/// Токен Студии читает только `StudioRunner`, наружу отсюда уходит `StudioState`: адрес с одноразовым кодом, но не токен.
@MainActor
final class StudioController {
    let runner: StudioRunner
    /// Опрос Студии и действия по утилитам: идёт, только пока открыт экран и сервер работает.
    let board: StudioBoardLoader
    private let defaults: UserDefaults
    private(set) var running = false
    private var screenIsOpen = false
    private var phaseSub: AnyCancellable?

    /// Чем утилита открывает адрес в браузере. Проверки подставляют своё.
    private let openURL: @MainActor (URL) -> Void

    init(runner: StudioRunner? = nil, defaults: UserDefaults = Kit.defaults,
         openURL: @escaping @MainActor (URL) -> Void = { StudioOpen.inBrowser($0) }) {
        self.defaults = defaults
        self.openURL = openURL
        let runner = runner ?? StudioRunner(folder: Self.storedFolder(defaults), launcher: StudioProcessLauncher(),
                                            network: StudioLiveNetwork(), system: StudioLiveSystem())
        self.runner = runner
        board = StudioBoardLoader(runner: runner)
        // @Published сообщает до записи: фазу берём из самого сообщения, а состояние не трогаем (снимок при уходе сервера стирает раннер).
        phaseSub = runner.$state.map(\.phase).removeDuplicates().sink { [weak self] phase in self?.syncPolling(phase, clear: false) }
    }

    /// Опрашиваем, пока открыт экран и сервер работает. Иначе опроса нет, а снимок утилит забыт.
    private func syncPolling(_ phase: StudioPhase? = nil, clear: Bool = true) {
        if running, screenIsOpen, (phase ?? runner.state.phase) == .running {
            board.start()
        } else {
            board.reset()
            if clear { runner.clearBoard() }
        }
    }

    /// Экран открыт в центре или в своём окне (аренда экрана).
    func screenOpen(_ open: Bool) {
        screenIsOpen = open
        syncPolling()
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
        syncPolling()
    }

    /// Выход процесса: сервер должен уйти раньше нас.
    func stopAndWait() {
        running = false
        runner.stopAndWait()
        syncPolling()
    }

    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: StudioAction.self, limit: StudioAction.wireLimit, state: { state }) { perform($0) }
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
        case .openInBrowser:
            guard running, runner.state.phase == .running else { return "Студия не запущена" }
            runner.openInBrowser(openURL)
            return nil
        case .newLogin:
            // Лаунчер 0.9.4 шлёт его сам, как только показывает страницу: открывать по нему браузер нельзя, кода он больше не получит.
            return "Экран Студии теперь родной: обнови лаунчер"
        case .reconnect:
            guard running else { return "Модуль сейчас не работает" }
            runner.stop()
            runner.start()
            return nil
        case .select(let id):
            guard StudioUnitID.isValid(id), runner.state.board?.unit(id) != nil else { return "Нет такой утилиты" }
            board.select(id)
            return nil
        case .deselect:
            board.select(nil)
            return nil
        default:
            return board.perform(action)
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
