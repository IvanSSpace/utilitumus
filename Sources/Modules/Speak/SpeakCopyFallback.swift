import AppKit
import Carbon.HIToolbox

// Запасной путь «Озвучки»: программа не отдала выделенное через AX (терминалы, часть программ на Electron) — скопировать его
// ⌘C и сразу вернуть буфер обмена как был. Единственный файл модуля с общим буфером обмена и синтетической клавишей:
// Tests/run-speak-privacy-check.sh держит это и смотрит, что здесь нет журналов, настроек и сети, а возврат буфера есть.
// Скопированный текст живёт только в возвращаемом значении.

/// Одна запись элемента буфера: тип и байты как есть.
struct SpeakPasteboardEntry: Equatable {
    let type: String
    let data: Data
}

/// Всё, что лежало в буфере: каждый элемент со всеми типами. Пустой массив — буфер был пуст.
struct SpeakPasteboardSnapshot: Equatable {
    var items: [[SpeakPasteboardEntry]]
}

/// Буфер обмена для копирования. Настоящий — `SpeakSystemPasteboard`.
@MainActor
protocol SpeakPasteboard: AnyObject {
    /// Система запрещает или спрашивает доступ к буферу (macOS 15.4+): тогда ⌘C не делаем и буфер не читаем.
    var accessRestricted: Bool { get }
    var changeCount: Int { get }
    func snapshot() -> SpeakPasteboardSnapshot
    /// Вернуть снимок целиком. Каждый элемент помечается `org.nspasteboard.TransientType`: менеджеры буфера
    /// не запишут вернувшееся в историю второй раз.
    func restore(_ snapshot: SpeakPasteboardSnapshot)
    func string() -> String?
    /// В буфере пароль: менеджеры паролей помечают его `org.nspasteboard.ConcealedType`.
    var concealed: Bool { get }
}

/// Синтетическое ⌘C. Настоящее — `SpeakSystemCopyKey`.
@MainActor
protocol SpeakCopyKey: AnyObject {
    /// Зажат ли сейчас ⌃, ⌥, ⇧ или ⌘.
    func modifiersHeld() -> Bool
    /// ⌘C в переднюю программу.
    func sendCopy()
}

/// Копирование выделенного через ⌘C с возвратом буфера.
@MainActor
final class SpeakCopyFallback {
    static let transientType = "org.nspasteboard.TransientType"
    static let concealedType = "org.nspasteboard.ConcealedType"
    /// Сколько ждать отпускания клавиш сочетания и с каким шагом, мс.
    static let releaseLimit = 500
    static let releaseStep = 20
    /// Сколько ждать копию после ⌘C и с каким шагом, мс. Шаг мелкий: чужой текст лежит в буфере не дольше пары шагов.
    static let copyLimit = 400
    static let copyStep = 10

    private let pasteboard: SpeakPasteboard
    private let key: SpeakCopyKey
    private let secureInput: SpeakSecureInput
    private let clock: SpeakClock

    init(pasteboard: SpeakPasteboard, key: SpeakCopyKey, secureInput: SpeakSecureInput, clock: SpeakClock) {
        self.pasteboard = pasteboard
        self.key = key
        self.secureInput = secureInput
        self.clock = clock
    }

    func copySelection() async -> SelectionResult {
        // Система спросила бы разрешения или отказала: ⌘C не делаем, буфер не читаем.
        if pasteboard.accessRestricted { return .pasteboardDenied }
        // ⌃⌥⇧ сочетания ещё зажаты: ⌘C ушло бы как ⌃⌥⇧⌘C. Ждём отпускания, но не дольше `releaseLimit`.
        var waited = 0
        while waited < Self.releaseLimit, key.modifiersHeld() {
            await clock.sleep(milliseconds: Self.releaseStep)
            waited += Self.releaseStep
        }
        // До ⌘C буфер не тронут: отмена и защищённый ввод, включённый за время ожидания, просто выходят.
        if Task.isCancelled { return .none }
        if secureInput.enabled() { return .secureInput }
        // Снимок прямо перед ⌘C: что попало в буфер, пока отпускали клавиши, тоже вернётся.
        let before = pasteboard.changeCount
        let saved = pasteboard.snapshot()
        // Буфер сменился, пока снимали: снимок неполный, возвращать его нельзя — и ⌘C не делаем.
        guard pasteboard.changeCount == before else { return .none }
        key.sendCopy()
        // Ждём копию. Отмена ожидание не обрывает: ⌘C уже ушло, и буфер надо вернуть, даже если копия придёт после отмены.
        var copied = false
        waited = 0
        while !copied, waited < Self.copyLimit {
            await clock.sleep(milliseconds: Self.copyStep)
            waited += Self.copyStep
            copied = pasteboard.changeCount != before
        }
        // Программа ничего не скопировала: буфер мы не меняли, возвращать нечего.
        guard copied else { return .none }
        // Буфер возвращается при любом выходе ниже.
        defer { pasteboard.restore(saved) }
        // Программа могла объявить типы, но ещё не положить данные: один шаг на то, чтобы она дописала.
        await clock.sleep(milliseconds: Self.copyStep)
        // Скопировался пароль: не читаем его вовсе.
        if pasteboard.concealed { return .secureField }
        guard !Task.isCancelled, let text = pasteboard.string(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return .text(text)
    }
}

// MARK: - Настоящие

/// `NSPasteboard`. Общий буфер даёт `general()`; проверки дают свой именованный буфер.
@MainActor
final class SpeakSystemPasteboard: SpeakPasteboard {
    private let board: () -> NSPasteboard?

    init(board: @escaping () -> NSPasteboard?) { self.board = board }

    /// Общий буфер обмена. В сборке со швом стенд отказывает: буфер автора не читается и не пишется,
    /// а `accessRestricted` тогда true — до ⌘C дело не доходит.
    static func general() -> SpeakSystemPasteboard {
        SpeakSystemPasteboard { Kit.standRefuses("общий буфер обмена") ? nil : NSPasteboard.general }
    }

    /// `.default` и `.alwaysAllow` — система не спросит; `.ask`, `.alwaysDeny` и неизвестное новое значение — не трогаем.
    @available(macOS 15.4, *)
    nonisolated static func restricted(_ behavior: NSPasteboard.AccessBehavior) -> Bool {
        switch behavior {
        case .default, .alwaysAllow: return false
        case .ask, .alwaysDeny: return true
        @unknown default: return true
        }
    }

    var accessRestricted: Bool {
        guard let board = board() else { return true }
        if #available(macOS 15.4, *) { return Self.restricted(board.accessBehavior) }
        return false
    }

    var changeCount: Int { board()?.changeCount ?? 0 }

    func snapshot() -> SpeakPasteboardSnapshot {
        guard let board = board() else { return SpeakPasteboardSnapshot(items: []) }
        let items = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { SpeakPasteboardEntry(type: type.rawValue, data: $0) } }
        }
        // Элемент, у которого не прочитался ни один тип, вернуть нечем.
        return SpeakPasteboardSnapshot(items: items.filter { !$0.isEmpty })
    }

    /// Одной записью: `clearContents` и `writeObjects` со всеми элементами. Пустой снимок — буфер просто очищается.
    func restore(_ snapshot: SpeakPasteboardSnapshot) {
        guard let board = board() else { return }
        board.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let transient = NSPasteboard.PasteboardType(SpeakCopyFallback.transientType)
        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            if !entries.contains(where: { $0.type == transient.rawValue }) { item.setData(Data(), forType: transient) }
            return item
        }
        board.writeObjects(items)
    }

    func string() -> String? { board()?.string(forType: .string) }

    var concealed: Bool {
        let type = NSPasteboard.PasteboardType(SpeakCopyFallback.concealedType)
        return board()?.pasteboardItems?.contains { $0.types.contains(type) } ?? false
    }
}

/// ⌘C как ⌘V у «Голоса» и «Буфера» (проверено там в работе): источник `.hidSystemState`, вход `.cghidEventTap` —
/// событие идёт в переднюю программу так же, как с клавиатуры, и его видят и терминалы, и Electron. Флаги ровно `.maskCommand`:
/// зажатые ⌃⌥⇧ к ним не добавляются, а ждём их отпускания всё равно — программа может смотреть на состояние клавиатуры.
@MainActor
final class SpeakSystemCopyKey: SpeakCopyKey {
    static let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    func modifiersHeld() -> Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection(Self.modifiers).isEmpty
    }

    func sendCopy() {
        if Kit.standRefuses("⌘C в переднюю программу") { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
