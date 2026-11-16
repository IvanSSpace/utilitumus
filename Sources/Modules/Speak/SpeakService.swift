import AppKit

/// Меню «Службы» → «Прочитать вслух» (NSServices в Info.plist утилиты, NSMessage `readAloud`). Универсальный доступ не нужен:
/// текст отдаёт сама программа. Берётся он только из буфера, который система передала службе, общий буфер обмена не трогается.
/// Текст никуда не пишется и не логируется: он уходит прямо в чтение.
@MainActor
final class SpeakService: NSObject {
    static let noText = "В выделении нет текста"

    private let controller: SpeakController
    /// Кому система отдаёт вызовы служб. Настоящий — `NSApp.servicesProvider`; проверки ставят подмену, система о них не узнаёт.
    private let install: (AnyObject?) -> Void
    private(set) var attached = false

    /// Ничего не регистрирует: провайдер ставит `attach`, его зовёт `start` модуля.
    init(controller: SpeakController, install: ((AnyObject?) -> Void)? = nil) {
        self.controller = controller
        self.install = install ?? { NSApp.servicesProvider = $0 }
        super.init()
    }

    func attach() {
        guard !attached else { return }
        install(self)
        attached = true
    }

    /// Модуль остановлен: система больше не достучится до чтения. Повторный вызов безвреден.
    func detach() {
        guard attached else { return }
        install(nil)
        attached = false
    }

    /// Вызов системы по пункту меню. Отказ уходит системе в `error`.
    @objc func readAloud(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        if let refusal = read(pboard) { error.pointee = refusal as NSString }
    }

    /// Отказ — короткий текст, nil — читаем. Модуль не работает — переданный буфер даже не открывается.
    func read(_ pboard: NSPasteboard) -> String? {
        guard controller.canStart else { return SpeakMessage.notRunning }
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.noText }
        return controller.speak(text: text)
    }
}
