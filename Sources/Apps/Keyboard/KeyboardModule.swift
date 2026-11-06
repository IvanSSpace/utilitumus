import Combine
import CoreGraphics
import SwiftUI

/// «Клавиатура» внутри своей утилиты. Слушает Fn и следит за приложениями только между `start` и остановкой.
///
/// Системное действие 🌐 и диктовка на двойном Fn — настройки пользователя, а не состояние утилиты. Поэтому
/// выход ради обновления и передача центру снимают только то, что держит утилита (`quit`), а возвращает настройки
/// выключение модуля и удаление: `stop`. Запомненные значения лежат в общем домене и нужны следующему хозяину.
@MainActor
final class KeyboardModule: SatelliteModule {
    let module = Module.keyboard
    private let controller = KeyboardController.shared

    /// Встроенному модулю журнал виден всегда, утилите — только под открытым экраном.
    init() { controller.setLogShown(false) }

    func start() { controller.start() }

    /// Утилиту выключили: настройки пользователя возвращаются. Центр зовёт `stop` и тогда, когда утилита включена,
    /// а центр старый и ведёт модуль сам (`SatelliteRole.mustRelease`): там настройки должны остаться как есть.
    func stop() {
        if Kit.defaults.object(forKey: SatelliteEnabled.key(linkID)) as? Bool == false {
            controller.stop()
        } else {
            controller.quit()
        }
    }

    /// Модуль у центра: tap снят, настройки на месте, их держит и применяет встроенный модуль.
    func enterPassive() { controller.quit() }
    func stopForUpdate() { controller.quit() }
    /// Удаление: единственное место, где утилита сама возвращает 🌐 и диктовку.
    func stopForUninstall() { controller.stop() }

    private var linkID: String { LinkIdentity.id(linkName) }

    // MARK: Статус

    private var listensToFn: Bool { controller.isStarted && controller.isOn(.fnLanguage) }

    /// Без языка, приложения и защищённого ввода: статус видят все на этом Mac, а они меняются каждую смену раскладки.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        let fn = controller.isOn(.fnLanguage), app = controller.isOn(.perAppLayout)
        guard fn || app else { return "нет включённых фишек" }
        if fn {
            guard controller.tapActive else { return "не слушаю клавиатуру" }
            if controller.systemUsage != 0 { return "системное действие 🌐 мешает" }
        }
        if fn && app { return "\(KeyboardFeature.fnLanguage.shortName) · \(KeyboardFeature.perAppLayout.shortName)" }
        return fn ? KeyboardFeature.fnLanguage.shortName : KeyboardFeature.perAppLayout.shortName
    }

    var attention: Bool {
        guard controller.isStarted else { return false }
        let fn = controller.isOn(.fnLanguage), app = controller.isOn(.perAppLayout)
        if !fn && !app { return true }
        return fn && (!controller.tapActive || controller.systemUsage != 0)
    }

    /// Шаги включённой фишки «Язык по Fn», как в чек-листе встроенного модуля.
    var setupSteps: [LinkSetupStep] {
        guard controller.isOn(.fnLanguage) else { return [] }
        return [
            LinkSetupStep(id: Self.inputStep, title: "Мониторинг ввода",
                          why: "Чтобы заметить тап по Fn/🌐; ничего не записывается",
                          icon: "keyboard.fill", kind: .permission, done: CGPreflightListenEventAccess()),
            LinkSetupStep(id: Self.globeStep, title: "Отключить системное действие 🌐",
                          why: "Иначе macOS тоже переключит язык, и он сменится дважды",
                          icon: "globe", kind: .system, buttonTitle: "Сделать", done: FnSystemAction.usage == 0),
            LinkSetupStep(id: Self.dictationStep, title: "Убрать диктовку с двойного Fn",
                          why: "Иначе двойной тап Fn вызовет диктовку. Если macOS спросит «Включить диктовку?» — нажми «Не сейчас»",
                          icon: "mic.slash.fill", kind: .recommendation, buttonTitle: "Сделать", required: false,
                          done: !FnSystemAction.dictationOnDoubleFn),
        ]
    }

    static let inputStep = "keyboard.input"
    static let globeStep = "keyboard.globe"
    static let dictationStep = "keyboard.dictation"

    func performSetupStep(_ id: String) -> String? {
        switch id {
        case Self.inputStep: controller.requestAccess()
        case Self.globeStep: controller.disableSystemAction()
        case Self.dictationStep: controller.disableDictationDoubleFn()
        default: return "Такого шага нет"
        }
        return nil
    }

    // MARK: Экран

    func screenOpen(_ open: Bool) { controller.setLogShown(open) }

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }
    var changes: AnyPublisher<Void, Never> { controller.objectWillChange.map { _ in }.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(KeyboardView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 560, height: 680) }
}
