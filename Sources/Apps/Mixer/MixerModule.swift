import Combine
import SwiftUI

/// «Микшер» внутри своей утилиты. Тапы создаются только для приложений с изменённой громкостью.
@MainActor
final class MixerModule: SatelliteModule {
    let module = Module.mixer
    private let controller = MixerController.shared

    init() { controller.runsInUtility = true }

    #if KIT_TEST_DEFAULTS
    /// Стенд не зависит от Mac: вместо опроса HAL и запущенных программ три готовые строки в каждом списке.
    func start() {
        func row(_ id: String, _ name: String) -> MixerApp { MixerApp(id: id, name: name, icon: NSImage(), volume: 1, muted: false) }
        controller.testPin(apps: [row("test.fixture.playing", "Играющее")],
                           idle: [row("test.fixture.idle", "Молчащее")],
                           preset: [row("test.fixture.preset", "Настроенное заранее")],
                           other: [row("test.fixture.other", "Редактор")])
    }
    #else
    func start() { controller.start() }
    #endif

    /// Тапы и агрегаты снимаются, звук приложений возвращается как был. Громкости остаются в настройках.
    func stop() { controller.stop() }

    /// Аренда экрана: опрос HAL раз в секунду только пока экран открыт, иначе раз в 4 с.
    func screenOpen(_ open: Bool) { controller.setScreenLease(open) }

    /// Только то, что меняется редко: разрешение пропадает или появляется, а не вместе с каждым треком.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        return controller.permissionProblem ? "Нет разрешения на запись системного звука" : "Громкость по программам"
    }

    /// Сохранённые громкости молча перестают действовать, пока нет разрешения: тап без данных снимается.
    var attention: Bool { controller.permissionProblem }

    /// Не обязателен: передача модуля не ждёт разрешения, оно заранее не проверяется. Шаг `done` снимается сам, как только
    /// тап снова получает звук.
    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: "mixer.capture", title: "Запись системного звука", why: "Система спросит при первом звуке",
                       icon: "waveform.badge.mic", buttonTitle: "Открыть настройки…", required: false, verifiable: false,
                       done: !controller.permissionProblem)]
    }

    func performSetupStep(_ id: String) -> String? {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"),
              NSWorkspace.shared.open(url) else { return "Не получилось открыть настройки" }
        return nil
    }

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }
    var changes: AnyPublisher<Void, Never> { controller.objectWillChange.map { _ in }.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(MixerView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 560, height: 640) }
}
