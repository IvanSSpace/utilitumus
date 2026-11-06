import Combine
import SwiftUI

/// «Нагрузка» внутри своей утилиты. Замеры идут, пока открыт экран (в центре или в своём окне); история пишется,
/// пока утилита работает. Остановить что-либо можно только по плану, который модуль сам построил и держит у себя.
@MainActor
final class LoadModule: SatelliteModule {
    let module = Module.load
    private var leased = false

    /// Ничего не запускает и не читает: хранилище создаётся при первом обращении.
    init() {}

    private var store: LoadStore { LoadStore.shared }

    func start() {
        // Окна центра у утилиты нет: считать или нет, решает аренда экрана.
        store.visibleGate = { true }
        store.start()
    }

    func stop() {
        if leased {
            leased = false
            store.screenDisappeared()
        }
        store.stop()
    }

    func screenOpen(_ open: Bool) {
        guard open != leased else { return }
        leased = open
        if open { store.screenAppeared() } else { store.screenDisappeared() }
    }

    /// Без цифр: строка уходит всем на этом Mac, а давление памяти меняется каждую секунду.
    func statusLine(passiveReason: String?) -> String {
        if store.isRunning { return "Следит за нагрузкой" }
        return passiveReason ?? "Выключена"
    }

    func state() -> Data { LinkWire.encoded(store.wireState) }
    func handle(_ action: Data) -> Data { store.handle(action) }

    /// Подвал (`live`) меняется каждый замер и сам по себе утилиту не будит: он едет с очередным снимком.
    var changes: AnyPublisher<Void, Never> {
        store.objectWillChange.merge(with: store.background.objectWillChange).map { _ in }.eraseToAnyPublisher()
    }

    func windowRoot() -> AnyView { AnyView(LoadScreen(store: store)) }
    var windowSize: CGSize { CGSize(width: 860, height: 720) }

    /// Остановка или действие над агентом идёт: перезапуск оборвал бы его на середине.
    var mayRestart: Bool { !store.stopRunning && !store.background.running }

    #if KIT_TEST_DEFAULTS
    func standCommand() { store.refreshNow() }
    #endif
}
