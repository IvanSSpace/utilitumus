import Combine
import SwiftUI

/// Конец трубы для обработчика SIGTERM: обработчик C не захватывает ничего, поэтому дескриптор лежит здесь.
nonisolated(unsafe) private var studioTerminationFD: Int32 = -1

/// «Студия» внутри своей утилиты. Включение запускает сервер из папки в настройках (или подключается к уже работающему),
/// выключение останавливает только свой. Токена Студии у центра нет: страницу ему открывает одноразовый код.
@MainActor
final class StudioModule: SatelliteModule {
    let module = Module.studio
    private let controller = StudioController()
    private var termination: DispatchSourceRead?

    /// Ничего не запускает: `init` зовут и копии из Finder.
    init() {}

    func start() {
        controller.start()
        stopServerOnTerminate()
    }
    func stop() { controller.stop() }

    /// SIGTERM от launchd (переустановка, выход из системы) обрывает процесс мимо `stop()`, и сервер Студии остался бы жить
    /// без хозяина. Обработчик сигнала только пишет байт в трубу (больше в нём делать нечего), а остановку делает читатель на
    /// главной очереди: свой сервер уходит (или добивается), потом выходим. Не `SIG_IGN`: игнор унаследовал бы и дочерний процесс.
    private func stopServerOnTerminate() {
        guard termination == nil else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        studioTerminationFD = fds[1]
        signal(SIGTERM) { _ in
            var byte: UInt8 = 1
            _ = write(studioTerminationFD, &byte, 1)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.controller.stopAndWait() }
            exit(0)
        }
        source.resume()
        termination = source
    }

    func statusLine(passiveReason: String?) -> String { controller.statusLine(passiveReason: passiveReason) }

    var attention: Bool { controller.state.phase == .failed }

    func state() -> Data { LinkWire.encoded(controller.state) }

    /// Остановленный модуль ничего не запускает и папку не меняет.
    func handle(_ action: Data) -> Data {
        guard controller.running else {
            return LinkWire.encoded(LinkReply(state: controller.state, error: "Модуль сейчас не работает"))
        }
        return controller.handle(action)
    }

    var changes: AnyPublisher<Void, Never> { controller.runner.objectWillChange.map { _ in }.eraseToAnyPublisher() }

    /// Своё окно утилиты: тот же экран на модели этого процесса.
    func windowRoot() -> AnyView { AnyView(StudioView(model: StudioWindowModel(controller: controller))) }
    var windowSize: CGSize { CGSize(width: 900, height: 760) }

    /// Идёт запуск сервера: перезапуск оборвал бы его на середине.
    var mayRestart: Bool { controller.state.phase != .starting }

    #if KIT_TEST_DEFAULTS
    func standCommand() {}
    #endif
}
