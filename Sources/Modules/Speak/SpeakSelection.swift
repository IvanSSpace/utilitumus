import ApplicationServices
import Foundation

/// Что удалось прочитать из выделения.
enum SelectionResult: Equatable {
    case text(String)
    /// Нет фокуса, нет выделения или программа его не отдаёт.
    case none
    /// Фокус в поле пароля: текст не читался.
    case secureField
    /// У утилиты нет Универсального доступа.
    case notTrusted
}

/// Чтение выделенного текста. Настоящее — `AXSelectionReader`; проверки ставят подмену, настоящий AX им не нужен.
@MainActor
protocol SelectionReading {
    func read() -> SelectionResult
}

/// Выделение через AX: фокус системы → его `AXSelectedText`. Без ⌘C и без буфера обмена. Права не просит:
/// запрос — отдельный шаг утилиты по кнопке.
struct AXSelectionReader: SelectionReading {
    /// Чтение идёт на главном потоке, а центр ждёт ответа утилиты 2 с: зависшую программу долго не ждём.
    static let timeout: Float = 0.5
    /// Подроль поля пароля (`kAXSecureTextFieldSubrole`). Некоторые программы ставят её ролью.
    static let secureRole = "AXSecureTextField"

    func read() -> SelectionResult {
        if Kit.standRefuses("читать выделение через AX") { return .none }
        guard AXIsProcessTrusted() else { return .notTrusted }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.timeout)
        guard let focused = Self.element(system, kAXFocusedUIElementAttribute) else { return .none }
        // Сначала роль: из поля пароля текст не запрашивается вовсе.
        if Self.string(focused, kAXSubroleAttribute) == Self.secureRole || Self.string(focused, kAXRoleAttribute) == Self.secureRole {
            return .secureField
        }
        guard let text = Self.string(focused, kAXSelectedTextAttribute),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return .text(text)
    }

    private static func element(_ owner: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ owner: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
