import AppKit

// «Озвучка»: как берётся выделенное — AX, Electron, копирование через ⌘C с возвратом буфера. Всё на подменах: AX, защищённый ввод,
// Electron, ⌘C, клавиши-модификаторы и паузы. Буфер — свой именованный (`NSPasteboard.withUniqueName`) под настоящим
// `SpeakSystemPasteboard`: снимок и возврат проверяются на настоящем NSPasteboard, но общий буфер обмена, настоящий ⌘C и AX
// проверка не трогает. Запуск: Tests/run-speak-copy-check.sh. Сборка со швом KIT_TEST_DEFAULTS.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let transient = "org.nspasteboard.TransientType"
let concealedType = "org.nspasteboard.ConcealedType"

/// Журнал вызовов подмен: по нему виден порядок шагов.
@MainActor final class Journal {
    var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
    func has(_ line: String) -> Bool { lines.contains(line) }
    func first(_ line: String) -> Int? { lines.firstIndex(of: line) }
    func last(_ line: String) -> Int? { lines.lastIndex(of: line) }
    func count(_ line: String) -> Int { lines.filter { $0 == line }.count }
}

@MainActor final class FakeFocus: SpeakFocus {
    let journal: Journal
    var isTrusted = true
    var current: SpeakFocusSelection = .empty
    /// Что фокус отдаст после `AXManualAccessibility`: Electron построил дерево AX.
    var afterManual: SpeakFocusSelection?
    var manualPIDs: [pid_t] = []
    init(_ journal: Journal) { self.journal = journal }
    func trusted() -> Bool { journal.add("trusted?"); return isTrusted }
    func selection() -> SpeakFocusSelection { journal.add("ax"); return current }
    func enableManualAccessibility(pid: pid_t) {
        journal.add("manual \(pid)")
        manualPIDs.append(pid)
        if let afterManual { current = afterManual }
    }
}

@MainActor final class FakeElectron: SpeakElectronProbe {
    var pid: pid_t? = 100
    var chromium: Set<pid_t> = []
    func frontmostPID() -> pid_t? { pid }
    func isChromium(pid: pid_t) -> Bool { chromium.contains(pid) }
}

@MainActor final class FakeSecureInput: SpeakSecureInput {
    let journal: Journal
    var on = false
    /// С какого по счёту вопроса защищённый ввод включён: так он «включается» посреди копирования.
    var onFromCall: Int?
    private var calls = 0
    init(_ journal: Journal) { self.journal = journal }
    func enabled() -> Bool {
        calls += 1
        journal.add("secure?")
        if let onFromCall, calls >= onFromCall { return true }
        return on
    }
}

@MainActor final class FakeClock: SpeakClock {
    let journal: Journal
    var slept: [Int] = []
    /// Что случилось за эту паузу: номер паузы и её длина. Так «программа» копирует позже, а задачу отменяют посреди ожидания.
    var onSleep: ((Int, Int) -> Void)?
    init(_ journal: Journal) { self.journal = journal }
    func sleep(milliseconds: Int) async {
        slept.append(milliseconds)
        journal.add("sleep \(milliseconds)")
        onSleep?(slept.count, milliseconds)
        await Task.yield()
    }
}

@MainActor final class FakeKey: SpeakCopyKey {
    let journal: Journal
    /// Сколько опросов подряд модификаторы ещё зажаты; Int.max — не отпускают вовсе.
    var heldPolls = 0
    var sends = 0
    /// Что «программа» делает на ⌘C.
    var onCopy: (() -> Void)?
    init(_ journal: Journal) { self.journal = journal }
    func modifiersHeld() -> Bool {
        let held = heldPolls > 0
        if held && heldPolls != Int.max { heldPolls -= 1 }
        journal.add(held ? "held" : "free")
        return held
    }
    func sendCopy() {
        sends += 1
        journal.add("⌘C")
        onCopy?()
    }
}

/// Тестовый двойник `NSPasteboard.AccessBehavior`: сама система есть только с macOS 15.4, а сборка — под 14.2.
enum Behavior { case normal, allow, ask, deny }

/// Шпион вокруг настоящего `SpeakSystemPasteboard` на именованном буфере: каждый вызов в журнале, запрет доступа задаётся.
@MainActor final class SpyPasteboard: SpeakPasteboard {
    let inner: SpeakSystemPasteboard
    let journal: Journal
    var behavior: Behavior?
    /// Кто-то пишет в буфер, пока модуль его снимает.
    var onSnapshot: (() -> Void)?
    init(_ board: NSPasteboard, _ journal: Journal) {
        inner = SpeakSystemPasteboard(board: { board })
        self.journal = journal
    }
    var accessRestricted: Bool {
        journal.add("access?")
        guard let behavior else { return inner.accessRestricted }
        return restricted(behavior)
    }
    var changeCount: Int { inner.changeCount }
    func snapshot() -> SpeakPasteboardSnapshot {
        journal.add("snapshot")
        let snap = inner.snapshot()
        onSnapshot?()
        return snap
    }
    func restore(_ snapshot: SpeakPasteboardSnapshot) {
        journal.add("restore")
        inner.restore(snapshot)
    }
    func string() -> String? {
        journal.add("string")
        return inner.string()
    }
    var concealed: Bool {
        journal.add("concealed?")
        return inner.concealed
    }
}

/// Отображение двойника на настоящее значение и решение настоящего кода.
func restricted(_ behavior: Behavior) -> Bool {
    guard #available(macOS 15.4, *) else {
        check(false, "NSPasteboard.accessBehavior нужна macOS 15.4+")
        return true
    }
    switch behavior {
    case .normal: return SpeakSystemPasteboard.restricted(.default)
    case .allow: return SpeakSystemPasteboard.restricted(.alwaysAllow)
    case .ask: return SpeakSystemPasteboard.restricted(.ask)
    case .deny: return SpeakSystemPasteboard.restricted(.alwaysDeny)
    }
}

struct Entry: Equatable {
    let type: String
    let data: Data
}

/// Что лежит в буфере: элементы, у каждого — типы по порядку и байты. Читает сама проверка, а не код модуля.
func contents(_ board: NSPasteboard) -> [[Entry]] {
    (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { Entry(type: type.rawValue, data: $0) } }
    }
}

var boards: [NSPasteboard] = []

/// Стенд: настоящий `SpeakSelectionReader` и `SpeakCopyFallback` на подменах и своём именованном буфере.
@MainActor final class Rig {
    let journal = Journal()
    let board = NSPasteboard.withUniqueName()
    let focus: FakeFocus
    let electron = FakeElectron()
    let secure: FakeSecureInput
    let clock: FakeClock
    let key: FakeKey
    let pasteboard: SpyPasteboard
    let reader: SpeakSelectionReader

    init() {
        boards.append(board)
        focus = FakeFocus(journal)
        secure = FakeSecureInput(journal)
        clock = FakeClock(journal)
        key = FakeKey(journal)
        pasteboard = SpyPasteboard(board, journal)
        let copier = SpeakCopyFallback(pasteboard: pasteboard, key: key, secureInput: secure, clock: clock)
        reader = SpeakSelectionReader(focus: focus, secureInput: secure, electron: electron, copier: copier, clock: clock)
        board.clearContents()
        board.setString("Что было в буфере", forType: .string)
    }

    func read(copyFallback: Bool = true) async -> SelectionResult { await reader.read(copyFallback: copyFallback) }

    /// «Программа» кладёт в буфер скопированное: строку и, если надо, ещё типы.
    func paste(_ text: String, extra: [(String, Data)] = []) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for (type, data) in extra { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        board.writeObjects([item])
    }

    /// На ⌘C программа сразу копирует `text`.
    func copies(_ text: String, extra: [(String, Data)] = []) {
        key.onCopy = { [unowned self] in paste(text, extra: extra) }
    }

    /// Буфер вообще трогали: спрашивали доступ, снимали, читали, возвращали или жали ⌘C.
    var touchedPasteboard: Bool {
        ["access?", "snapshot", "restore", "string", "concealed?", "⌘C"].contains { journal.has($0) }
    }
}

Task { @MainActor in
    await run()
    for board in boards { board.releaseGlobally() }
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()

@MainActor func run() async {
    let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? ""
    check(suite.hasPrefix("local.utilitumus.test.kit.speak"), "настройки только в тестовом suite «Озвучки» (\(suite))")

    // MARK: 0. Нет права
    var rig = Rig()
    rig.focus.isTrusted = false
    rig.focus.current = .text("не прочитается")
    check(await rig.read() == .notTrusted, "нет Универсального доступа — .notTrusted")
    check(!rig.journal.has("ax") && !rig.touchedPasteboard, "без права ни AX, ни буфера")

    // MARK: (а) AX дал текст — буфер не трогали
    rig = Rig()
    var before = contents(rig.board)
    var count = rig.board.changeCount
    rig.focus.current = .text("Привет из AX")
    check(await rig.read() == .text("Привет из AX"), "(а) AX дал текст — он и читается")
    check(!rig.touchedPasteboard && rig.key.sends == 0, "(а) буфер не трогали: ни доступа, ни снимка, ни ⌘C")
    check(contents(rig.board) == before && rig.board.changeCount == count, "(а) буфер тот же, changeCount тот же")
    check(rig.clock.slept.isEmpty, "(а) без пауз")

    // MARK: (б) AX пуст, ⌘C скопировал: прочитали, буфер вернулся байт в байт
    rig = Rig()
    rig.board.clearContents()
    let first = NSPasteboardItem()
    first.setString("старое содержимое", forType: .string)
    first.setData(Data("<b>старое</b>".utf8), forType: .html)
    first.setData(Data([0x00, 0xFF, 0x01, 0xFE, 0x00, 0x00, 0x7F, 0x80]), forType: NSPasteboard.PasteboardType("com.example.speak.binary"))
    let second = NSPasteboardItem()
    second.setData(Data((0..<256).map { UInt8(($0 * 37 + 11) % 256) }), forType: .png)
    second.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: NSPasteboard.PasteboardType("com.example.speak.other"))
    rig.board.writeObjects([first, second])
    before = contents(rig.board)
    check(before.count == 2 && before[0].count >= 3 && before[1].count >= 2, "(б) в буфере два элемента, у каждого несколько типов")
    let answer = "Ответ агента в терминале: всё собралось."
    rig.copies(answer, extra: [("public.html", Data("<i>ответ</i>".utf8))])
    check(await rig.read() == .text(answer), "(б) AX пуст — прочитано скопированное через ⌘C")
    let after = contents(rig.board)
    check(after.count == before.count, "(б) элементов столько же (\(after.count))")
    check(zip(before, after).allSatisfy { b, a in a.filter { $0.type != transient } == b },
          "(б) каждый элемент вернулся байт в байт: те же типы в том же порядке и те же данные, бинарные тоже")
    check(after.allSatisfy { $0.filter { $0.type == transient } == [Entry(type: transient, data: Data())] },
          "(б) на каждом вернувшемся элементе ровно один TransientType с пустыми данными")
    check(rig.board.string(forType: .string) == "старое содержимое", "(б) скопированного в буфере не осталось")
    let j = rig.journal
    if let snap = j.first("snapshot"), let copy = j.first("⌘C"), let read = j.first("string"), let restore = j.first("restore") {
        check(snap < copy && copy < read && read < restore, "(б) порядок: снимок → ⌘C → чтение строки → возврат (\(j.lines.filter { !$0.hasPrefix("sleep") }))")
    } else {
        check(false, "(б) в журнале нет снимка, ⌘C, чтения или возврата: \(j.lines)")
    }
    check(j.count("restore") == 1 && rig.key.sends == 1, "(б) ровно одно ⌘C и один возврат")
    check(j.first("secure?").map { $0 < (j.first("ax") ?? -1) } == true, "(б) защищённый ввод спрошен раньше AX")

    // Пустой исходный буфер — после чтения снова пуст.
    rig = Rig()
    rig.board.clearContents()
    check(contents(rig.board).isEmpty, "(б) исходный буфер пуст")
    rig.copies("Скопировано в пустой буфер")
    check(await rig.read() == .text("Скопировано в пустой буфер"), "(б) из пустого буфера: прочитано")
    check(contents(rig.board).isEmpty && (rig.board.types ?? []).isEmpty, "(б) пустой исходный буфер после чтения снова пуст")

    // Скопированное — только пробелы: не читаем, буфер вернулся.
    rig = Rig()
    before = contents(rig.board)
    rig.copies("  \n\t ")
    check(await rig.read() == .none, "(б) скопированы одни пробелы — «нет текста»")
    check(rig.journal.has("restore") && contents(rig.board).map { $0.filter { $0.type != transient } } == before, "(б) и буфер вернулся")

    // Скопированное помечено как пароль: не читаем его вовсе, буфер вернулся.
    rig = Rig()
    before = contents(rig.board)
    rig.copies("пароль-123", extra: [(concealedType, Data())])
    check(await rig.read() == .secureField, "скопирован пароль (ConcealedType) — как поле пароля")
    check(!rig.journal.has("string") && rig.journal.has("restore"), "пароль: строка не читалась, буфер вернулся")
    check(contents(rig.board).map { $0.filter { $0.type != transient } } == before, "пароль: в буфере снова прежнее")

    // Программа объявила копию, но данные положила на шаг позже: модуль ждёт шаг и читает их.
    rig = Rig()
    let late = "Данные пришли на шаг позже"
    rig.key.onCopy = { [unowned rig] in rig.board.clearContents() }
    rig.clock.onSleep = { [unowned rig] _, _ in
        if rig.journal.count("sleep \(SpeakCopyFallback.copyStep)") == 2, rig.board.string(forType: .string) == nil {
            rig.board.setString(late, forType: .string)
        }
    }
    check(await rig.read() == .text(late), "копия в два шага (clearContents, потом данные) — прочитана")
    check(rig.board.string(forType: .string) == "Что было в буфере", "и буфер вернулся")

    // MARK: (в) ⌘C не изменил changeCount — «нет текста», буфер не тронут
    rig = Rig()
    before = contents(rig.board)
    count = rig.board.changeCount
    check(await rig.read() == .none, "(в) ⌘C ничего не скопировал — «нет текста»")
    check(rig.key.sends == 1 && !rig.journal.has("restore") && !rig.journal.has("string"), "(в) возврата не было, строка не читалась")
    check(contents(rig.board) == before && rig.board.changeCount == count, "(в) буфер тот же, changeCount тот же")
    check(rig.clock.slept.filter { $0 == SpeakCopyFallback.copyStep }.reduce(0, +) == SpeakCopyFallback.copyLimit,
          "(в) копию ждали ровно \(SpeakCopyFallback.copyLimit) мс")

    // Буфер сменился, пока его снимали: снимок неполный — ⌘C не делается.
    rig = Rig()
    rig.pasteboard.onSnapshot = { [unowned rig] in
        rig.board.clearContents()
        rig.board.setString("чужая запись", forType: .string)
    }
    rig.copies("не скопируется")
    check(await rig.read() == .none && rig.key.sends == 0 && !rig.journal.has("restore"), "буфер сменился во время снимка — ни ⌘C, ни возврата")

    // MARK: (г) поле пароля и защищённый ввод — ни AX-текста, ни ⌘C, ни снимка
    rig = Rig()
    rig.focus.current = .secureField
    check(await rig.read() == .secureField, "(г) поле пароля — .secureField")
    check(!rig.touchedPasteboard, "(г) поле пароля: ни доступа к буферу, ни снимка, ни ⌘C")
    rig = Rig()
    rig.secure.on = true
    rig.focus.current = .text("не прочитается")
    rig.electron.chromium = [100]
    check(await rig.read() == .secureInput, "(г) защищённый ввод — .secureInput")
    check(!rig.journal.has("ax") && rig.focus.manualPIDs.isEmpty, "(г) защищённый ввод: AX даже не спрошен, Electron не включён")
    check(!rig.touchedPasteboard, "(г) защищённый ввод: ни доступа к буферу, ни снимка, ни ⌘C")
    // Включился, пока отпускали клавиши: до ⌘C не дошло.
    rig = Rig()
    rig.secure.onFromCall = 2
    rig.key.heldPolls = 2
    rig.copies("не скопируется")
    check(await rig.read() == .secureInput, "(г) защищённый ввод включился посреди копирования — .secureInput")
    check(rig.key.sends == 0 && !rig.journal.has("snapshot") && !rig.journal.has("restore"), "(г) и ни снимка, ни ⌘C")

    // MARK: (д) доступ к буферу .ask и .alwaysDeny — ⌘C не делается
    check(!restricted(.normal) && !restricted(.allow), "(д) .default и .alwaysAllow — можно")
    check(restricted(.ask) && restricted(.deny), "(д) .ask и .alwaysDeny — нельзя")
    for behavior in [Behavior.ask, .deny] {
        rig = Rig()
        before = contents(rig.board)
        rig.pasteboard.behavior = behavior
        rig.copies("не скопируется")
        check(await rig.read() == .pasteboardDenied, "(д) \(behavior) — .pasteboardDenied, сообщение про доступ")
        check(rig.key.sends == 0 && !rig.journal.has("snapshot") && !rig.journal.has("string") && !rig.journal.has("restore"),
              "(д) \(behavior): ни снимка, ни ⌘C, ни чтения")
        check(contents(rig.board) == before, "(д) \(behavior): буфер не тронут")
    }
    rig = Rig()
    rig.pasteboard.behavior = .normal
    rig.copies("можно")
    check(await rig.read() == .text("можно"), "(д) .default — копирование идёт")

    // MARK: (е) переключатель выключен — ⌘C не делается
    rig = Rig()
    rig.copies("не скопируется")
    check(await rig.read(copyFallback: false) == .none, "(е) копирование выключено — «нет текста»")
    check(!rig.touchedPasteboard && rig.key.sends == 0, "(е) ни доступа к буферу, ни снимка, ни ⌘C")

    // MARK: (ж) Electron: AXManualAccessibility один раз на процесс
    rig = Rig()
    rig.electron.chromium = [100, 200]
    rig.focus.afterManual = .text("Ответ из Electron")
    rig.copies("не нужно")
    check(await rig.read() == .text("Ответ из Electron"), "(ж) Electron: после AXManualAccessibility выделение видно")
    check(rig.focus.manualPIDs == [100], "(ж) AXManualAccessibility поставлен программе 100")
    check(rig.clock.slept == [SpeakSelectionReader.electronPause], "(ж) пауза \(SpeakSelectionReader.electronPause) мс перед повтором")
    if let manual = rig.journal.first("manual 100"), let pause = rig.journal.first("sleep \(SpeakSelectionReader.electronPause)") {
        check(manual < pause && rig.journal.count("ax") == 2 && (rig.journal.last("ax") ?? 0) > pause, "(ж) AX спрошен снова после паузы")
    } else {
        check(false, "(ж) нет AXManualAccessibility или паузы: \(rig.journal.lines)")
    }
    check(!rig.touchedPasteboard, "(ж) ⌘C не понадобился: буфер не трогали")
    // Второе нажатие в той же программе: заново не ставится, паузы нет.
    rig.focus.afterManual = nil
    rig.focus.current = .empty
    rig.clock.slept = []
    check(await rig.read(copyFallback: false) == .none, "(ж) второе нажатие, AX пуст, копирование выключено — «нет текста»")
    check(rig.focus.manualPIDs == [100] && rig.clock.slept.isEmpty, "(ж) тому же процессу AXManualAccessibility не ставится снова, паузы нет")
    rig.electron.pid = 200
    _ = await rig.read(copyFallback: false)
    check(rig.focus.manualPIDs == [100, 200], "(ж) другой процесс Electron — ему ставится")
    // Не Electron.
    rig = Rig()
    rig.electron.pid = 300
    rig.copies("из терминала")
    check(await rig.read() == .text("из терминала"), "(ж) не Electron: сразу ⌘C")
    check(rig.focus.manualPIDs.isEmpty && !rig.clock.slept.contains(SpeakSelectionReader.electronPause),
          "(ж) не Electron — AXManualAccessibility не ставится и паузы 150 мс нет")
    rig = Rig()
    rig.electron.pid = nil
    rig.electron.chromium = [100]
    _ = await rig.read(copyFallback: false)
    check(rig.focus.manualPIDs.isEmpty, "(ж) передней программы не понять — ничего не ставится")
    // Electron, повтор тоже пуст: дальше ⌘C.
    rig = Rig()
    rig.electron.chromium = [100]
    rig.copies("Electron отдал только через ⌘C")
    check(await rig.read() == .text("Electron отдал только через ⌘C"), "(ж) Electron и после паузы пуст — ⌘C")
    check(rig.focus.manualPIDs == [100] && rig.key.sends == 1, "(ж) сначала AXManualAccessibility, потом одно ⌘C")

    // MARK: (з) ⌘C только после отпускания модификаторов
    rig = Rig()
    rig.key.heldPolls = 3
    rig.copies("после отпускания")
    check(await rig.read() == .text("после отпускания"), "(з) клавиши отпустили — прочитано")
    if let lastHeld = rig.journal.last("held"), let free = rig.journal.first("free"), let copy = rig.journal.first("⌘C"),
       let snap = rig.journal.first("snapshot") {
        check(rig.journal.count("held") == 3 && lastHeld < free && free < snap && snap < copy,
              "(з) порядок: зажаты ×3 → отпущены → снимок → ⌘C (\(rig.journal.lines.filter { !$0.hasPrefix("sleep") }))")
    } else {
        check(false, "(з) в журнале нет опроса клавиш или ⌘C: \(rig.journal.lines)")
    }
    check(Array(rig.clock.slept.prefix(3)) == Array(repeating: SpeakCopyFallback.releaseStep, count: 3), "(з) опрос шагом \(SpeakCopyFallback.releaseStep) мс")
    // Не отпускают вовсе: ⌘C уходит по тайм-ауту, не раньше.
    rig = Rig()
    rig.key.heldPolls = Int.max
    rig.copies("по тайм-ауту")
    check(await rig.read() == .text("по тайм-ауту"), "(з) клавиши не отпустили — ⌘C по тайм-ауту")
    let releaseWaits = rig.clock.slept.filter { $0 == SpeakCopyFallback.releaseStep }.count
    check(releaseWaits * SpeakCopyFallback.releaseStep == SpeakCopyFallback.releaseLimit,
          "(з) ждали ровно \(SpeakCopyFallback.releaseLimit) мс (\(releaseWaits) шагов)")
    check((rig.journal.first("⌘C") ?? -1) > (rig.journal.last("held") ?? Int.max), "(з) ⌘C после последнего опроса клавиш")

    // MARK: (и) отмена
    // Отменили, пока ждали копию, а программа скопировала позже: буфер всё равно вернулся, текст не отдан.
    rig = Rig()
    before = contents(rig.board)
    var task: Task<SelectionResult, Never>?
    rig.clock.onSleep = { [unowned rig] _, ms in
        guard ms == SpeakCopyFallback.copyStep else { return }
        let waits = rig.journal.count("sleep \(ms)")
        if waits == 1 { task?.cancel() }
        if waits == 3 { rig.paste("Скопировано после отмены") }
    }
    task = Task { [rig] in await rig.read() }
    check(await task?.value == SelectionResult.none, "(и) отменили во время ожидания копии — текст не отдан")
    check(rig.key.sends == 1 && rig.journal.count("restore") == 1, "(и) копия пришла после отмены — буфер всё равно возвращён")
    check(contents(rig.board).map { $0.filter { $0.type != transient } } == before, "(и) в буфере снова прежнее")
    // Отменили, пока ждали отпускания клавиш: до ⌘C не дошло, буфер не тронут.
    rig = Rig()
    before = contents(rig.board)
    count = rig.board.changeCount
    rig.key.heldPolls = 5
    rig.copies("не скопируется")
    rig.clock.onSleep = { n, _ in if n == 1 { task?.cancel() } }
    task = Task { [rig] in await rig.read() }
    check(await task?.value == SelectionResult.none, "(и) отменили до ⌘C — «нет текста»")
    check(rig.key.sends == 0 && !rig.journal.has("snapshot") && !rig.journal.has("restore"), "(и) до ⌘C: ни снимка, ни ⌘C, ни возврата")
    check(contents(rig.board) == before && rig.board.changeCount == count, "(и) буфер не тронут")
    // Отменили после паузы Electron: дальше не идём.
    rig = Rig()
    rig.electron.chromium = [100]
    rig.copies("не скопируется")
    rig.clock.onSleep = { _, ms in if ms == SpeakSelectionReader.electronPause { task?.cancel() } }
    task = Task { [rig] in await rig.read() }
    check(await task?.value == SelectionResult.none && rig.key.sends == 0 && !rig.touchedPasteboard, "(и) отменили на паузе Electron — без ⌘C")

    // MARK: (к) повторное нажатие, пока текст берётся
    rig = Rig()
    let synth = FakeSynth()
    let hotKey = FakeHotKey()
    let controller = SpeakController(synthesizer: synth, reader: rig.reader, hotKey: hotKey, trusted: { true },
                                     preferredLanguages: { ["ru-RU"] }, openScreen: {})
    controller.start()
    rig.key.heldPolls = 3
    rig.copies("Одно ⌘C на два нажатия")
    rig.clock.onSleep = { n, _ in if n == 1 { hotKey.press() } }
    hotKey.press()
    await controller.reading?.value
    await settle()
    check(rig.key.sends == 1 && rig.journal.count("restore") == 1, "(к) второе нажатие посреди копирования: одно ⌘C, один возврат")
    check(synth.spoken.count == 1 && synth.last?.text == "Одно ⌘C на два нажатия" && controller.phase == .speaking,
          "(к) прочитано один раз")
    check(controller.reading == nil, "(к) после чтения можно нажимать снова")
    controller.stop()
}
