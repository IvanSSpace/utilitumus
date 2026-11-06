import Combine
import SwiftUI

/// «Вентиляторы» внутри своей утилиты. Вентиляторов утилита касается только между `start` и остановкой;
/// служба сама вернёт «Авто», если утилита умрёт (сторож удержания в `FanHelper`).
@MainActor
final class FansModule: SatelliteModule {
    let module = Module.fans
    private let controller = FanController.shared
    private let installer = FanHelperInstaller.shared
    private let game = GameModeController.shared
    private let model = BuiltInFansModel.shared
    /// Состояние уходит центру только пока открыт его экран: такт 2 с меняет почти всё.
    private var leased = false
    private let lease = PassthroughSubject<Void, Never>()
    /// Перед самообновлением вентиляторы отданы системе и управление на паузе.
    private var heldForUpdate = false
    private var forwarding: Set<AnyCancellable> = []

    init() {
        for source in [controller.objectWillChange, installer.objectWillChange, game.objectWillChange] {
            source.sink { [weak self] in
                guard let self, self.leased else { return }
                self.lease.send()
            }.store(in: &forwarding)
        }
    }

    func start() {
        // Самообновление сорвалось: управление возвращается.
        if heldForUpdate {
            heldForUpdate = false
            controller.resumeAfterFailedUpdate()
        }
        controller.start()
    }

    func stop() {
        controller.stop()
        installer.moduleRunning = false
    }

    /// Бандл сейчас заменят, и служба после этого может не принять процесс: вентиляторы отдаются заранее.
    /// Так же делает обновление центра. Перезапуск `kickstart -k` без этого бросил бы вентилятор в ручном режиме.
    func stopForUpdate() {
        heldForUpdate = true
        controller.holdForUpdate()
    }

    func screenOpen(_ open: Bool) {
        leased = open
        installer.screenOpen = open
        if open {
            installer.refresh()
            lease.send()
        }
    }

    var changes: AnyPublisher<Void, Never> { lease.eraseToAnyPublisher() }
    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }

    /// Без оборотов и температур: статус виден всем на этом Mac, и он не должен меняться каждый такт.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        switch installer.status {
        case .notInstalled: return "Нужен доступ к вентиляторам"
        case .outdated: return "Доступ нужно обновить"
        case .installed, .ready: break
        }
        if controller.conflictingApp != nil { return "Вентиляторами управляет другая программа" }
        if controller.safetyTripped { return "Перегрев: вентиляторы у macOS" }
        if controller.fullPower { return "Полная мощность" }
        if game.isActive { return "Максимум в игре" }
        return controller.configs.contains { $0.mode != .auto } ? "Вентиляторы по настройкам" : "Вентиляторы у macOS"
    }

    var attention: Bool { installer.status == .outdated || controller.safetyTripped }

    var quickActions: [LinkQuickAction] {
        guard installer.status == .ready, controller.conflictingApp == nil else { return [] }
        return [
            LinkQuickAction(title: controller.fullPower ? "Выключить полную мощность" : "Полная мощность",
                            icon: controller.fullPower ? "bolt.slash.fill" : "bolt.fill",
                            action: LinkWire.encoded(FansAction.setFullPower(!controller.fullPower))),
            LinkQuickAction(title: "Все в режим «Авто»", icon: "arrow.uturn.backward",
                            action: LinkWire.encoded(FansAction.setAllAuto)),
        ]
    }

    /// Те же слова, что у шага встроенного модуля (`Module.setupSteps`): на экране центра они не должны отличаться.
    /// Устаревший помощник команд не получает, но обновляется плашкой на экране модуля: без этого шага экран открыт.
    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: Self.helperStep, title: "Помощник для вентиляторов", why: "Пароль администратора, один раз",
                       icon: "key.fill", kind: .permission, buttonTitle: "Дать доступ…",
                       verifiable: true, done: installer.status != .notInstalled, error: installer.lastError)]
    }

    private static let helperStep = "fans.helper"

    /// Окно пароля идёт не на главном потоке (`FanHelperInstaller.install`), поэтому ответ уходит сразу.
    func performSetupStep(_ id: String) -> String? {
        guard id == Self.helperStep else { return "Такого шага нет" }
        guard installer.status == .notInstalled || installer.status == .outdated else { return nil }
        installer.install()
        return nil
    }

    func windowRoot() -> AnyView { AnyView(FansView(model: model)) }
    var windowSize: CGSize { CGSize(width: 760, height: 640) }
    /// Бандл меняется только после `stopForUpdate`, и вентиляторы к этому времени уже у системы.
    var mayRestart: Bool { true }

    #if KIT_TEST_DEFAULTS
    func standCommand() { controller.fullPower.toggle() }
    #endif
}
