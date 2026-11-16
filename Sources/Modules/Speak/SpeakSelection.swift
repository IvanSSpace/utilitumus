import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Что удалось прочитать из выделения.
enum SelectionResult: Equatable {
    case text(String)
    /// Нет фокуса, нет выделения, программа его не отдаёт и ⌘C ничего не скопировал.
    case none
    /// Фокус в поле пароля или скопированное помечено как пароль: текст не читался.
    case secureField
    /// Включён защищённый ввод (`IsSecureEventInputEnabled`): ни AX-текста, ни ⌘C.
    case secureInput
    /// Система запрещает или спрашивает доступ к буферу обмена: ⌘C не делали.
    case pasteboardDenied
    /// У утилиты нет Универсального доступа.
    case notTrusted
}

/// Чтение выделенного текста. Настоящее — `SpeakSelectionReader`; проверки ставят подмену, настоящий AX им не нужен.
/// Асинхронное: паузы (Electron, отпускание клавиш, ожидание копии) не держат главный поток.
@MainActor
protocol SelectionReading {
    /// `copyFallback` — можно ли, если AX ничего не дал, скопировать выделенное через ⌘C.
    func read(copyFallback: Bool) async -> SelectionResult
}

/// Что видно в фокусе через AX прямо сейчас.
enum SpeakFocusSelection: Equatable {
    case text(String)
    case empty
    case secureField
}

/// AX: право, выделение в фокусе, дерево AX у Electron. Настоящее — `AXSpeakFocus`.
@MainActor
protocol SpeakFocus: AnyObject {
    func trusted() -> Bool
    /// Сначала роль: из поля пароля текст не запрашивается вовсе.
    func selection() -> SpeakFocusSelection
    /// `AXManualAccessibility` = true у программы: Electron и Chromium после этого строят дерево AX и отдают выделение.
    func enableManualAccessibility(pid: pid_t)
}

/// Передняя программа и её движок. Настоящее — `BundleElectronProbe`.
@MainActor
protocol SpeakElectronProbe: AnyObject {
    func frontmostPID() -> pid_t?
    func isChromium(pid: pid_t) -> Bool
}

/// Защищённый ввод: его включают поля паролей и «Безопасный ввод с клавиатуры» терминалов. Настоящее — `CarbonSecureInput`.
@MainActor
protocol SpeakSecureInput: AnyObject {
    func enabled() -> Bool
}

/// Пауза без блокировки главного потока. Отмена её не прерывает: начатое ⌘C доводится до возврата буфера.
@MainActor
protocol SpeakClock: AnyObject {
    func sleep(milliseconds: Int) async
}

/// Выделенный текст по шагам:
/// 0. нет Универсального доступа — `.notTrusted`;
/// 1. защищённый ввод или поле пароля — стоп, ничего не читаем; иначе `AXSelectedText` в фокусе;
/// 2. пусто, а передняя программа на Electron или Chromium — один раз на процесс включить ей `AXManualAccessibility`,
///    подождать `electronPause` и повторить шаг 1;
/// 3. всё ещё пусто — копирование через ⌘C с возвратом буфера (`SpeakCopyFallback`), если оно включено.
/// Текст не задерживается: он только в возвращаемом значении.
@MainActor
final class SpeakSelectionReader: SelectionReading {
    /// Сколько Electron строит дерево AX после `AXManualAccessibility`, мс.
    static let electronPause = 150

    private let focus: SpeakFocus
    private let secureInput: SpeakSecureInput
    private let electron: SpeakElectronProbe
    private let copier: SpeakCopyFallback
    private let clock: SpeakClock
    /// Процессы, которым уже включили `AXManualAccessibility`. Только в памяти: после перезапуска утилиты включится снова, это безвредно.
    private var manualAccessibility: Set<pid_t> = []

    init(focus: SpeakFocus, secureInput: SpeakSecureInput, electron: SpeakElectronProbe, copier: SpeakCopyFallback, clock: SpeakClock) {
        self.focus = focus
        self.secureInput = secureInput
        self.electron = electron
        self.copier = copier
        self.clock = clock
    }

    /// Настоящие зависимости. В сборке со швом AX и ⌘C отказывают через `Kit.standRefuses`, а буфер обмена — именованный тестовый.
    static func system() -> SpeakSelectionReader {
        let clock = SpeakMainClock()
        let secureInput = CarbonSecureInput()
        let copier = SpeakCopyFallback(pasteboard: SpeakSystemPasteboard.general(), key: SpeakSystemCopyKey(),
                                       secureInput: secureInput, clock: clock)
        return SpeakSelectionReader(focus: AXSpeakFocus(), secureInput: secureInput, electron: BundleElectronProbe(),
                                    copier: copier, clock: clock)
    }

    func read(copyFallback: Bool) async -> SelectionResult {
        guard focus.trusted() else { return .notTrusted }
        let first = look()
        guard first == .none else { return first }
        if let pid = electron.frontmostPID(), !manualAccessibility.contains(pid), electron.isChromium(pid: pid) {
            manualAccessibility.insert(pid)
            focus.enableManualAccessibility(pid: pid)
            await clock.sleep(milliseconds: Self.electronPause)
            if Task.isCancelled { return .none }
            let second = look()
            guard second == .none else { return second }
        }
        guard copyFallback, !Task.isCancelled else { return .none }
        return await copier.copySelection()
    }

    /// Шаг 1. Защищённый ввод проверяется раньше AX: тогда не запрашивается даже роль фокуса.
    private func look() -> SelectionResult {
        if secureInput.enabled() { return .secureInput }
        switch focus.selection() {
        case .secureField: return .secureField
        case .empty: return .none
        case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text)
        }
    }
}

// MARK: - Настоящие зависимости

/// Выделение через AX: фокус системы → его `AXSelectedText`. Права не просит: запрос — отдельный шаг утилиты по кнопке.
/// В сборке со швом чтение и запись отказывают: стенд не трогает чужие программы.
@MainActor
final class AXSpeakFocus: SpeakFocus {
    /// Чтение идёт на главном потоке, а центр ждёт ответа утилиты 2 с: зависшую программу долго не ждём.
    static let timeout: Float = 0.5
    /// Подроль поля пароля (`kAXSecureTextFieldSubrole`). Некоторые программы ставят её ролью.
    static let secureRole = "AXSecureTextField"
    /// Атрибут Electron (и Chromium): включить дерево AX без VoiceOver.
    static let manualAccessibility = "AXManualAccessibility"

    func trusted() -> Bool { AXIsProcessTrusted() }

    func selection() -> SpeakFocusSelection {
        if Kit.standRefuses("читать выделение через AX") { return .empty }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.timeout)
        guard let focused = Self.element(system, kAXFocusedUIElementAttribute) else { return .empty }
        if Self.string(focused, kAXSubroleAttribute) == Self.secureRole || Self.string(focused, kAXRoleAttribute) == Self.secureRole {
            return .secureField
        }
        guard let text = Self.string(focused, kAXSelectedTextAttribute) else { return .empty }
        return .text(text)
    }

    func enableManualAccessibility(pid: pid_t) {
        if Kit.standRefuses("включить AXManualAccessibility у программы") { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        // Отказ (не Electron, старая версия) безвреден: тогда остаётся ⌘C.
        _ = AXUIElementSetAttributeValue(app, Self.manualAccessibility as CFString, kCFBooleanTrue)
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

/// Передняя программа по `NSWorkspace`, движок — по фреймворкам в её бандле. Список сверен с программами на Mac автора
/// (2026-11, macOS 26): «Electron Framework» — Orca, Visual Studio Code, Cursor, Claude, Discord, Notion, Obsidian, Figma
/// (Slack тоже собран на Electron); «Google Chrome Framework» — Chrome. «Chromium Framework», «Microsoft Edge Framework»
/// и «Brave Browser Framework» — те же сборки Chromium у Chromium, Edge и Brave, на этом Mac их нет. Не входят CEF
/// («Chromium Embedded Framework»: Spotify, OBS), ArcCore (Arc, Dia) и «Yandex Framework»: как они отвечают на
/// `AXManualAccessibility`, не проверено. Им, как и всем прочим, остаётся ⌘C.
@MainActor
final class BundleElectronProbe: SpeakElectronProbe {
    static let frameworks = [
        "Electron Framework.framework",
        "Google Chrome Framework.framework",
        "Chromium Framework.framework",
        "Microsoft Edge Framework.framework",
        "Brave Browser Framework.framework",
    ]

    func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func isChromium(pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let folder = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return Self.frameworks.contains { name in
            (try? folder.appendingPathComponent(name, isDirectory: true).checkResourceIsReachable()) == true
        }
    }
}

/// `IsSecureEventInputEnabled` — общий для системы флаг: включён у любой программы, значит включён.
@MainActor
final class CarbonSecureInput: SpeakSecureInput {
    func enabled() -> Bool { IsSecureEventInputEnabled() }
}

/// Пауза на очереди главного потока: отмена задачи её не обрывает (см. `SpeakClock`).
@MainActor
final class SpeakMainClock: SpeakClock {
    func sleep(milliseconds: Int) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { done.resume() }
        }
    }
}
