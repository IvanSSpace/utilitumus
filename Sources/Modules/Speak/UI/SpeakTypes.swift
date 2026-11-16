import Carbon.HIToolbox
import Foundation

/// Ключи настроек, общие для утилиты и экрана. Домен настроек у центра и утилиты один.
/// Текст чтения сюда не пишется никогда: только скорость, голоса и сочетание.
enum SpeakKeys {
    static let speed = "Speak.Speed"
    static let pinnedVoices = "Speak.PinnedVoices"
    static let keyCode = "Speak.HotKeyCode"
    static let modifiers = "Speak.HotKeyModifiers"

    /// ⌃⌥⇧S.
    static let defaultKeyCode = UInt32(kVK_ANSI_S)
    static let defaultModifiers = UInt32(controlKey | optionKey | shiftKey)
}

/// Скорость чтения — множитель к обычной.
enum SpeakSpeed {
    static let range: ClosedRange<Double> = 0.5...3.0
    static let step = 0.25
    static let normal = 1.0

    /// В диапазон и до сотых. Не число — nil.
    static func clamped(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return (min(max(value, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    /// К соседней отметке шага в сторону `direction`: с 1,1 «+» даёт 1,25, «−» даёт 1. За краем диапазона стоит на краю.
    static func stepped(_ value: Double, _ direction: Int) -> Double {
        guard direction != 0 else { return value }
        // Запас на погрешность: 1,0 / 0,25 должно остаться ровно отметкой 4.
        let mark = value / step
        let next = direction > 0 ? (mark + 1e-9).rounded(.down) + 1 : (mark - 1e-9).rounded(.up) - 1
        return min(max(next * step, range.lowerBound), range.upperBound)
    }

    /// Сохранённое значение; чужое или пустое — обычная скорость.
    static func stored(_ object: Any?) -> Double {
        (object as? Double).flatMap(clamped) ?? normal
    }
}

/// Сколько текста читаем за раз.
enum SpeakText {
    static let limit = 50_000

    /// Не длиннее `limit` символов. Считает не дальше лимита: длинное выделение целиком не обходится.
    static func fits(_ text: String) -> Bool {
        guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) else { return true }
        return end == text.endIndex
    }
}

/// Сообщения пользователю. Только готовые строки: текст выделения в них не подставляется.
enum SpeakMessage {
    static let needAccess = "Нужен Универсальный доступ: дай его кнопкой в разделе «Универсальный доступ» или читай через меню «Службы»"
    static let noSelection = "Не вижу выделенный текст: попробуй через меню Службы"
    static let secureField = "Из поля пароля не читаю"
    static let tooLong = "Текст длиннее 50 000 символов, выдели меньше"
    static let notRunning = "Модуль сейчас не может читать"
    static let hotKeyBusy = "Это сочетание занято, выбери другое"
}
