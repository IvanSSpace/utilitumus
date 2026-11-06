import AppKit
import Combine
import SwiftUI

// Клавиатура: состояние и действия по связи, проверки действий, экран до и после переноса на модель.
// Запуск: Tests/run-keyboard-wire-check.sh <папка>. Модуль не запускается: start() нигде не зовётся, tap не создаётся.

#if !KIT_TEST_DEFAULTS
#error("Без шва KIT_TEST_DEFAULTS Kit.defaults — настоящие настройки")
#endif

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Скрипт подставляет её вместо `false` в `logShown` обоих экранов: журнал раскрывается только нажатием.
nonisolated(unsafe) var testLogShown = false

/// Модель для экрана: как будущая модель утилиты, живёт только на состоянии из связи.
@MainActor final class FakeKeyboardModel: KeyboardModel {
    @Published var state: KeyboardState
    var actions: [String] = []

    init(_ state: KeyboardState) { self.state = state }

    var trigger: FnTrigger { get { state.trigger } set { state.trigger = newValue } }
    var mode: LayoutMode { get { state.mode } set { state.mode = newValue } }
    var currentName: String { state.currentName }
    var tapActive: Bool { state.tapActive }
    var inputAccess: Bool { state.inputAccess }
    var systemUsage: Int? { state.systemUsage }
    var secureInputApp: String? { state.secureInputApp }
    var logTail: [KeyboardLog.Entry] { state.logTail }
    var logCount: Int { state.logCount }
    var repairResult: String? { state.repairResult }
    var layouts: [KeyboardLayoutItem] { state.layouts }
    var newAppLayout: String? { get { state.newAppLayout } set { state.newAppLayout = newValue } }
    var excludedApps: [String] { state.excludedApps }

    func isOn(_ feature: KeyboardFeature) -> Bool { state.features.contains(feature.rawValue) }
    func setFeature(_ feature: KeyboardFeature, on: Bool) { actions.append("setFeature") }
    func addExcluded(_ id: String) { actions.append("addExcluded") }
    func removeExcluded(_ id: String) { actions.append("removeExcluded") }
    func repair() { actions.append("repair") }
    func copyLog() { actions.append("copyLog") }
    func refreshAccess() { actions.append("refreshAccess") }
    func refreshSystem() { actions.append("refreshSystem") }
}

/// Старый экран в стенде берёт контроллер из этой переменной: скрипт подставляет её вместо `KeyboardController.shared`.
@MainActor var baselineModel = FakeKeyboardModel(sampleState(features: []))

@MainActor func sampleState(features: [KeyboardFeature], usage: Int? = 0, access: Bool = true, tap: Bool = true,
                            secure: String? = nil, excluded: [String] = [], newApp: String? = nil,
                            repair: String? = nil, trigger: FnTrigger = .onRelease, mode: LayoutMode = .lastTwo) -> KeyboardState {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return KeyboardState(features: features.map(\.rawValue), trigger: trigger, mode: mode, currentName: "Русская",
                         tapActive: tap, inputAccess: access, systemUsage: usage, secureInputApp: secure,
                         logTail: (0..<3).map { KeyboardLog.Entry(date: start.addingTimeInterval(Double($0) * 61), text: "запись \($0)") },
                         logCount: 3, repairResult: repair,
                         layouts: [KeyboardLayoutItem(id: "com.apple.keylayout.ABC", name: "ABC"),
                                   KeyboardLayoutItem(id: "com.apple.keylayout.Russian", name: "Русская")],
                         newAppLayout: newApp, excludedApps: excluded)
}

// MARK: - Кодирование

func sorted(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(value)) ?? Data()
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    let data = sorted(value)
    guard let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value && sorted(back) == data
}

/// Как будет читать общий помощник связи: разбор и сверка с кодированием, чужие ключи так не проходят.
func canonicalAction(_ text: String) -> KeyboardAction? {
    guard let action = try? JSONDecoder().decode(KeyboardAction.self, from: Data(text.utf8)),
          sorted(action) == Data(text.utf8) else { return nil }
    return action
}

let allActions: [KeyboardAction] = [
    .setFeature(feature: .fnLanguage, on: true), .setTrigger(.onPress), .setMode(.cycle),
    .setNewAppLayout("com.apple.keylayout.ABC"), .setNewAppLayout(nil), .addExcluded("com.example.app"),
    .removeExcluded("com.example.app"), .repair, .copyLog, .refreshAccess, .refreshSystem, .requestAccess,
    .disableSystemAction, .disableDictationDoubleFn, .disableAllSystemActions,
]

@MainActor func checkCoding() {
    check(allActions.allSatisfy(roundTrips), "все \(allActions.count) значений действий (14 видов) проходят JSON туда и обратно")
    let full = sampleState(features: [.fnLanguage, .perAppLayout], usage: 3, access: false, tap: false, secure: "Terminal",
                           excluded: ["com.a", "com.b"], newApp: "com.apple.keylayout.ABC", repair: "итог",
                           trigger: .onPress, mode: .cycle)
    let empty = sampleState(features: [], usage: nil)
    check(roundTrips(full) && roundTrips(empty), "состояние проходит JSON туда и обратно, с полями и без необязательных")
    let newer = String(decoding: sorted(empty), as: UTF8.self)
        .replacingOccurrences(of: "\"features\":[]", with: "\"features\":[\"future\"],\"newField\":1")
    let decoded = try? JSONDecoder().decode(KeyboardState.self, from: Data(newer.utf8))
    check(decoded?.features == ["future"], "фишка и поле новее центра не ломают разбор состояния")

    for bad in [#"{"explode":{}}"#, #"{"setFeature":{"feature":"ghost","on":true}}"#, #"{"setTrigger":{"_0":"x"}}"#,
                #"{"setMode":{"_0":1}}"#, #"{"addExcluded":{"_0":1}}"#, #"{"repair":{},"x":1}"#, #"{"repair":{"x":1}}"#,
                #"{"setNewAppLayout":{"_0":null}}"#, "{}", "[]",
                #"{"repair":{},"copyLog":{}}"#, #"{"setTrigger":{"_0":"onPress"},"x":1}"#,
                #"{"setFeature":{"feature":"fnLanguage","on":true,"x":1}}"#, #"{"setFeature":{"feature":"fnLanguage"}}"#,
                #"{"setNewAppLayout":{"_0":"a","x":1}}"#, #"{"setNewAppLayout":{"x":1}}"#, #"{"repair":1}"#,
                #"{"addExcluded":{}}"#, #"{"setMode":{"_0":"cycle"},"setMode":{"_0":"lastTwo"}}"#] {
        check(canonicalAction(bad) == nil, "разбор отказывает: \(bad)")
    }
    // Сам разбор, без сверки с кодированием: вторая сетка не должна прикрывать первую.
    for bad in [#"{"repair":{},"x":1}"#, #"{"repair":{"x":1}}"#, #"{"repair":{},"copyLog":{}}"#, #"{"setTrigger":{"_0":"onPress","x":1}}"#,
                #"{"setFeature":{"feature":"fnLanguage","on":true,"x":1}}"#, #"{"setNewAppLayout":{"_0":"a","x":1}}"#,
                #"{"setNewAppLayout":{"x":1}}"#, #"{"addExcluded":{"_0":"a","x":1}}"#, #"{"setMode":{"_0":1}}"#] {
        check((try? JSONDecoder().decode(KeyboardAction.self, from: Data(bad.utf8))) == nil, "сам разбор отказывает: \(bad)")
    }
    check(canonicalAction(#"{"repair":{}}"#) == .repair, "разбор принимает настоящее действие")
}

// MARK: - Проверки действий на настоящем контроллере

let settingsPrefix = "Keyboard."

func settingsSnapshot() -> NSDictionary {
    var all: [String: Any] = [:]
    for (name, store) in [("standard", UserDefaults.standard), ("kit", Kit.defaults)] {
        for (key, value) in store.dictionaryRepresentation() where key.hasPrefix(settingsPrefix) { all[name + "." + key] = value }
    }
    return all as NSDictionary
}

func clearSettings() {
    for store in [UserDefaults.standard, Kit.defaults] {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix(settingsPrefix) { store.removeObject(forKey: key) }
    }
}

@MainActor func refuses(_ controller: KeyboardController, _ action: KeyboardAction, _ name: String) {
    let state = controller.wireState, settings = settingsSnapshot()
    Stub.calls = []
    let error = controller.handle(action)
    check(error != nil && controller.wireState == state && settingsSnapshot() == settings && Stub.calls.isEmpty,
          "отказ, состояние и настройки те же, система не тронута: \(name) → \(error ?? "нет отказа")")
}

@MainActor func checkHandle() {
    clearSettings()
    let c = KeyboardController()
    c.setFeature(.fnLanguage, on: false)
    check(c.handle(.refreshAccess) == nil && c.layouts.count == 2, "refreshAccess: раскладки из системы")
    let abc = "com.apple.keylayout.ABC"

    refuses(c, .setFeature(feature: .capsLock, on: true), "фишка «Скоро»")
    refuses(c, .setNewAppLayout("com.apple.keylayout.Ghost"), "раскладка, которой нет")
    for (id, name) in [("", "пустой"), (String(repeating: "a", count: 256), "256 символов"), ("/Applications/Calculator.app", "путь"),
                       ("com.example\n", "перевод строки"), ("com.ex ample", "пробел"), ("com.приложение", "не ASCII")] {
        refuses(c, .addExcluded(id), "addExcluded \(name)")
    }
    refuses(c, .removeExcluded("com.not.listed"), "убрать то, чего нет в списке")
    refuses(c, .requestAccess, "запрос доступа при выключенном «Языке по Fn»")
    refuses(c, .disableSystemAction, "отключить 🌐 при выключенном «Языке по Fn»")
    refuses(c, .disableDictationDoubleFn, "снять диктовку при выключенном «Языке по Fn»")
    refuses(c, .disableAllSystemActions, "отключить всё при выключенном «Языке по Fn»")

    // Разрешённое доходит до контроллера.
    Stub.calls = []
    KeyboardController.onFeaturesChanged = { Stub.calls.append("features.changed") }
    check(c.handle(.setFeature(feature: .perAppLayout, on: true)) == nil && c.isOn(.perAppLayout) && Stub.calls == ["features.changed"],
          "setFeature включает фишку и сообщает центру через onFeaturesChanged")
    KeyboardController.onFeaturesChanged = {}
    check(c.handle(.setTrigger(.onPress)) == nil && c.trigger == .onPress, "setTrigger")
    check(c.handle(.setMode(.cycle)) == nil && c.mode == .cycle, "setMode")
    check(c.handle(.setNewAppLayout(abc)) == nil && c.newAppLayout == abc, "setNewAppLayout: выданный id")
    check(c.handle(.setNewAppLayout(nil)) == nil && c.newAppLayout == nil, "setNewAppLayout: «как было»")
    check(c.handle(.addExcluded("com.example_1.App-2")) == nil && c.excludedApps == ["com.example_1.App-2"], "addExcluded")
    check(c.handle(.addExcluded("com.example_1.App-2")) == nil && c.excludedApps.count == 1, "addExcluded: повтор без дубля")
    check(KeyboardController().excludedApps == ["com.example_1.App-2"], "список сохранён в настройках")
    check(c.handle(.removeExcluded("com.example_1.App-2")) == nil && c.excludedApps.isEmpty, "removeExcluded")
    check(c.handle(.addExcluded(String(repeating: "a", count: 255))) == nil, "addExcluded: 255 символов можно")
    for n in 1..<KeyboardController.maxExcludedApps { _ = c.handle(.addExcluded("com.fill.\(n)")) }
    check(c.excludedApps.count == KeyboardController.maxExcludedApps, "список заполнен до предела")
    refuses(c, .addExcluded("com.one.more"), "список полон")
    check(c.handle(.addExcluded("com.fill.1")) == nil, "список полон: уже добавленное не ошибка")
    for id in c.excludedApps { _ = c.handle(.removeExcluded(id)) }

    Stub.calls = []
    check(c.handle(.repair) == nil && c.repairResult?.contains("Модуль выключен") == true && Stub.calls.isEmpty,
          "repair при неработающем модуле только сообщает, систему не трогает")
    Stub.usage = 2
    check(c.handle(.refreshSystem) == nil && c.systemUsage == 2, "refreshSystem")
    Stub.usage = 1
    _ = c.handle(.refreshSystem)

    _ = c.handle(.setFeature(feature: .fnLanguage, on: true))
    for (action, call) in [(KeyboardAction.disableSystemAction, "disable"), (.disableDictationDoubleFn, "disableDictation"),
                           (.disableAllSystemActions, "disableAll")] {
        Stub.calls = []
        check(c.handle(action) == nil && Stub.calls == [call], "при включённом «Языке по Fn» доходит до заглушки: \(call)")
    }
    check(c.tapActive == false, "tap не создан")
    check(c.wireState.features == ["fnLanguage", "perAppLayout"], "features в порядке экрана")
    check(roundTrips(c.wireState), "wireState настоящего контроллера проходит JSON")
    KeyboardLog.shared.flush()
    let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("utilitumus-keyboard-test.log")
    check(FileManager.default.fileExists(atPath: log.path), "журнал стенда пишется во временную папку, а не в настоящий журнал")
    let realLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utilitumus/keyboard.log")
    check(!FileManager.default.fileExists(atPath: realLog.path), "в подменённой домашней папке журнала нет")
    clearSettings()
}

// MARK: - Утилита: остановки, журнал под экраном, шаги

func decodedState(_ data: Data) -> KeyboardState? { try? JSONDecoder().decode(KeyboardState.self, from: data) }

@MainActor func checkModule() {
    clearSettings()
    // Только «Раскладка для каждого приложения»: ей tap не нужен, она ничего не пишет в систему.
    KeyboardFeature.fnLanguage.isOn = false
    KeyboardFeature.perAppLayout.isOn = true
    let module = KeyboardModule()
    let controller = KeyboardController.shared
    let enabledKey = SatelliteEnabled.key(LinkIdentity.id(module.linkName))
    func restored(_ name: String, _ expected: Bool, _ body: () -> Void) {
        module.start()
        Stub.calls = []
        let wasStarted = controller.isStarted
        body()
        check(wasStarted && !controller.isStarted, "\(name): модуль был запущен и остановлен")
        check(Stub.calls.contains("restore") == expected, "\(name): 🌐 и диктовка \(expected ? "возвращены" : "не тронуты") (\(Stub.calls))")
    }
    check(!controller.isStarted, "init утилиты ничего не запускает")
    Kit.defaults.set(true, forKey: enabledKey)
    restored("передача центру (enterPassive)", false) { module.enterPassive() }
    restored("обновление (stopForUpdate)", false) { module.stopForUpdate() }
    restored("утилита включена, stop зовёт старый центр", false) { module.stop() }
    restored("удаление (stopForUninstall)", true) { module.stopForUninstall() }
    Kit.defaults.set(false, forKey: enabledKey)
    restored("утилиту выключили (stop)", true) { module.stop() }
    Kit.defaults.removeObject(forKey: enabledKey)
    restored("ключа включённости нет (stop)", false) { module.stop() }
    module.start()
    module.enterPassive()
    module.enterPassive()
    check(!controller.isStarted, "повторный enterPassive безвреден")

    // Журнал уходит в состояние и пинги только под открытым экраном.
    // «Язык по Fn» включён, но модуль не запущен: tap не создаётся, а действие доходит до заглушки и пишет в журнал.
    controller.setFeature(.fnLanguage, on: true)
    let fnModule = KeyboardModule()
    var pings = 0
    let sink = fnModule.changes.sink { pings += 1 }
    let disableDictation = LinkWire.encoded(KeyboardAction.disableDictationDoubleFn)
    let before = KeyboardLog.shared.count
    let reply = fnModule.handle(disableDictation)
    check(!String(decoding: reply, as: UTF8.self).contains("\"error\""), "действие принято: \(String(decoding: reply, as: UTF8.self).prefix(80))")
    check(KeyboardLog.shared.count > before, "запись попала в журнал")
    check(pings == 0, "экран закрыт: запись журнала не будит центр (пингов \(pings))")
    check(decodedState(fnModule.state())?.logCount == 0 && decodedState(fnModule.state())?.logTail.isEmpty == true,
          "экран закрыт: журнал в состоянии пуст")
    fnModule.screenOpen(true)
    check(pings > 0, "экран открыт: текущий журнал отправлен (\(pings))")
    check((decodedState(fnModule.state())?.logCount ?? 0) > 0, "экран открыт: журнал в состоянии")
    let open = pings
    _ = fnModule.handle(disableDictation)
    check(pings > open, "экран открыт: новая запись будит центр")
    fnModule.screenOpen(false)
    let closed = pings
    _ = fnModule.handle(disableDictation)
    check(pings == closed, "экран закрыт снова: тишина")
    sink.cancel()

    // Шаги и статус.
    let steps = fnModule.setupSteps
    check(steps.map(\.id) == ["keyboard.input", "keyboard.globe", "keyboard.dictation"], "шаги «Языка по Fn»")
    check(steps.map(\.required) == [true, true, false] && steps.map(\.kind) == [.permission, .system, .recommendation], "обязательность и виды шагов")
    Stub.calls = []
    check(fnModule.performSetupStep("keyboard.globe") == nil && Stub.calls == ["disable"], "шаг «🌐» доходит до заглушки")
    check(fnModule.performSetupStep("keyboard.dictation") == nil && Stub.calls == ["disable", "disableDictation"], "шаг «диктовка» доходит до заглушки")
    check(fnModule.performSetupStep("keyboard.nothing") != nil, "незнакомый шаг отвергнут")
    controller.setFeature(.fnLanguage, on: false)
    check(fnModule.setupSteps.isEmpty, "без «Языка по Fn» шагов нет")
    let line = fnModule.statusLine(passiveReason: nil)
    check(line == "по приложениям" && !line.contains("Русск") && !line.contains("ABC"), "статус без названия раскладки: «\(line)»")
    check(fnModule.statusLine(passiveReason: "Ждём передачу от центра") == "Ждём передачу от центра", "статус пассивной утилиты")
    check(!fnModule.attention, "незапущенный модуль не требует внимания")
    clearSettings()
}

// MARK: - Экран

@MainActor enum Shot {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    static func take(_ view: some View) async -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.background(Color.black).dsThemed()))
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 1200)
        window.contentView = host
        try? await Task.sleep(nanoseconds: 400_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, _ name: String, out: String) {
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/png/\(name).png"))
    }
}

func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData else {
        return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh)
    }
    let pixelBytes = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * pixelBytes, pb + y * a.bytesPerRow + x * pixelBytes, pixelBytes) != 0 {
            count += 1
        }
    }
    return count
}

/// Как первое открытие экрана: фишки читаются из настроек старым экраном и из модели новым.
@MainActor func seedFeatures(_ state: KeyboardState) {
    for feature in KeyboardFeature.allCases where feature.isAvailable { feature.isOn = state.features.contains(feature.rawValue) }
}

@MainActor func checkScreen(out: String) async {
    let excluded = ["com.apple.calculator", "com.example.removed"]
    let scenarios: [(String, KeyboardState, Bool)] = [
        ("fn-ok", sampleState(features: [.fnLanguage]), false),
        ("fn-conflict", sampleState(features: [.fnLanguage], usage: 1, tap: false), false),
        ("fn-no-access", sampleState(features: [.fnLanguage], usage: nil, access: false, tap: false), false),
        ("fn-secure", sampleState(features: [.fnLanguage], secure: "Terminal", trigger: .onPress, mode: .cycle), false),
        ("both-log", sampleState(features: [.fnLanguage, .perAppLayout], usage: 3, repair: "Итог починки"), true),
        ("app-empty", sampleState(features: [.perAppLayout]), false),
        ("app-list", sampleState(features: [.perAppLayout], excluded: excluded, newApp: "com.apple.keylayout.Russian"), false),
        ("app-removed-layout", sampleState(features: [.perAppLayout], newApp: "com.apple.keylayout.Gone"), false),
        ("none", sampleState(features: []), false),
    ]
    var shots: [NSBitmapImageRep] = []
    for (name, state, logShown) in scenarios {
        seedFeatures(state)
        testLogShown = logShown
        baselineModel = FakeKeyboardModel(state)
        let before = await Shot.take(BaselineKeyboardView())
        let model = FakeKeyboardModel(try! JSONDecoder().decode(KeyboardState.self, from: sorted(state)))
        let after = await Shot.take(KeyboardView(model: model))
        Shot.save(after, name, out: out)
        let diff = differingPixels(before, after)
        check(diff == 0, "\(name): старый и новый экран, разных пикселей \(diff) из \(after.pixelsWide * after.pixelsHigh)")
        check(model.actions == ["refreshAccess", "refreshSystem"], "\(name): при открытии экран обновляет доступ и систему")
        shots.append(after)
    }
    testLogShown = false
    let same = zip(shots, shots.dropFirst()).filter { differingPixels($0, $1) == 0 }.count
    check(same == 0, "соседние состояния различаются, снимки не пустые")

    // Настоящий контроллер против экрана на его же состоянии, прочитанном из JSON: состояние несёт всё, что видно.
    // Первый случай раскрывает настройки Fn и журнал, второй — настройки раскладки по приложениям.
    // tapActive и secureInputApp без работающего tap настоящими не бывают: они проверены на модели выше.
    for fnOn in [true, false] {
        clearSettings()
        Stub.usage = 1
        Stub.current = Stub.layouts[1]
        KeyboardFeature.fnLanguage.isOn = fnOn
        KeyboardFeature.perAppLayout.isOn = true
        testLogShown = fnOn
        let real = KeyboardController()
        _ = real.handle(.refreshAccess)
        _ = real.handle(.addExcluded("com.apple.calculator"))
        _ = real.handle(.setNewAppLayout("com.apple.keylayout.Russian"))
        _ = real.handle(.setTrigger(.onPress))
        _ = real.handle(.setMode(.cycle))
        _ = real.handle(.repair)
        if fnOn { _ = real.handle(.disableAllSystemActions) }
        let live = await Shot.take(KeyboardView(model: real))
        let state = try! JSONDecoder().decode(KeyboardState.self, from: sorted(real.wireState))
        seedFeatures(state)
        baselineModel = FakeKeyboardModel(state)
        let old = await Shot.take(BaselineKeyboardView())
        let remote = await Shot.take(KeyboardView(model: FakeKeyboardModel(state)))
        let name = fnOn ? "настоящий контроллер, Fn" : "настоящий контроллер, по приложениям"
        Shot.save(live, fnOn ? "real-fn" : "real-app", out: out)
        check(real.tapActive == false && state.currentName == "Русская" && (state.logCount > 0) == fnOn, "\(name): tap нет, имя раскладки и журнал на месте")
        let oldDiff = differingPixels(live, old), remoteDiff = differingPixels(live, remote)
        check(oldDiff == 0, "\(name) и старый экран, разных пикселей \(oldDiff)")
        check(remoteDiff == 0, "\(name) и модель из JSON, разных пикселей \(remoteDiff)")
    }
    testLogShown = false
    clearSettings()
}

@main
enum Main {
    static func main() {
        // Журнал контроллера идёт в домашнюю папку: до первой записи убеждаемся, что она подменена.
        let out = CommandLine.arguments[1]
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard home == URL(fileURLWithPath: "\(out)/home").resolvingSymlinksInPath().path,
              Bundle.main.bundleIdentifier == nil else {
            print("FAIL домашняя папка не подменена или есть bundle id: \(home)")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            checkCoding()
            checkHandle()
            checkModule()
            await checkScreen(out: out)
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
