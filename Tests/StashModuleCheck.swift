import AppKit
import Combine

// Модуль «Стеш» в утилите: защита своих программ, общий с центром домен записи, один писатель, аренда экрана.
// Запуск: Tests/run-stash-module-check.sh. Все программы поддельные: ни одна настоящая не закрывается и не запускается.
// Настройки только в тестовом домене Kit (KIT_TEST_SUITE); настоящий стеш не читается и не пишется.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await pause(0.05)
    }
    return condition()
}

final class FakeApp: NSRunningApplication, @unchecked Sendable {
    let fakeID: String
    var terminations = 0
    init(_ id: String) { fakeID = id; super.init() }
    override var bundleIdentifier: String? { fakeID }
    override var localizedName: String? { fakeID }
    override var bundleURL: URL? { URL(fileURLWithPath: "/nonexistent/\(fakeID).app") }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
    override var isTerminated: Bool { false }
    override var processIdentifier: pid_t { -1 }
    override func terminate() -> Bool { terminations += 1; return true }
    override func forceTerminate() -> Bool { terminations += 1; return true }
}

let keys = ["StashedApps", "StashedApps.unreadable", "StashExcludedBundleIDs", "StashScenarios"]
func reset() { keys.forEach(Kit.defaults.removeObject(forKey:)) }

func decodedReply(_ data: Data) -> LinkReply<StashState>? { try? JSONDecoder().decode(LinkReply<StashState>.self, from: data) }

let record = StashedApp(bundleID: "test.closed", path: "/nonexistent/closed.app", name: "Закрытая",
                        windows: [StashedWindow(title: "", x: 1, y: 2, width: 300, height: 200),
                                  StashedWindow(title: "", x: 5, y: 6, width: 300, height: 200)])
let scenario = StashScenario(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Работа", bundleIDs: ["test.a"])

/// Лаунчер, каждая утилита и помощники: ни один не попадает в список и не закрывается, как бы ни назвали их в действии.
@MainActor func protection() async {
    var ids = Set(Kit.ownBundleIDs)
    for module in Module.allCases { ids.insert(KitLink.bundleID(module.rawValue)) }
    ids.insert(Kit.hubBundleID)
    check(ids.count >= Module.allCases.count + 1, "список своих программ не пуст: \(ids.count)")
    check(ids.contains("local.utilitumus.app.stash") && ids.contains(Kit.hubBundleID), "в списке и утилита Стеша, и лаунчер")
    check(ids.allSatisfy { !StashStore.isEligible(bundleID: $0) }, "isEligible не пускает ни одну свою программу")
    check(!StashStore.isEligible(bundleID: "com.apple.finder"), "Finder защищён")
    for fake in ["local.utilitumus.evil", "local.utilitumus.app.x.y"] {
        check(StashStore.isEligible(bundleID: fake), "чужая с похожим id закрывается как обычная: \(fake)")
    }

    let defaults = Kit.defaults
    reset()
    let store = StashStore(defaults: defaults)
    var calls = 0
    let ours = ids.sorted().map(FakeApp.init)
    let other = FakeApp("test.other")
    store.system = StashSystem(runningApps: { ours + [other] }, open: { _, _ in calls += 1; throw CocoaError(.fileNoSuchFile) })
    store.refresh()
    check(store.wireState.running.map(\.bundleID) == ["test.other"], "в списке одна чужая программа: \(store.wireState.running.map(\.bundleID))")
    let before = encode(store.wireState)
    for id in ids.sorted() {
        let reply = store.handle(LinkWire.encoded(StashAction.stash(bundleIDs: [id])))
        check(decodedReply(reply)?.error != nil, "stash по id своей программы отвергнут: \(id)")
    }
    let mixed = decodedReply(store.handle(LinkWire.encoded(StashAction.stash(bundleIDs: ["test.other", Kit.hubBundleID]))))
    check(mixed?.error != nil, "stash вместе с лаунчером отвергнут целиком")
    check(encode(store.wireState) == before && ours.allSatisfy { $0.terminations == 0 } && other.terminations == 0 && calls == 0,
          "после отказов ничего не закрыто, не запущено и не изменено")
    // Даже если свой попал в явный список (как раньше при сравнении по Bundle.main), закрыть его нельзя.
    await store.stash(ours)
    check(ours.allSatisfy { $0.terminations == 0 }, "прямой stash по своим программам ничего не закрыл")
    reset()
}

func encode(_ value: some Encodable) -> Data { LinkWire.encoded(value) }

/// Запись о закрытых программах лежит в `Kit.defaults`: центр и утилита читают одну и ту же.
@MainActor func continuity() async {
    let defaults = Kit.defaults
    reset()
    // Встроенный стеш центра: тот же вызов, что у общего экземпляра центра.
    let builtIn = StashStore()
    builtIn.system = StashSystem(runningApps: { [] }, open: { _, _ in throw CocoaError(.fileNoSuchFile) })
    defaults.set(try! JSONEncoder().encode([record]), forKey: "StashedApps")
    defaults.set(try! JSONEncoder().encode([scenario]), forKey: "StashScenarios")
    defaults.set(["test.excluded"], forKey: "StashExcludedBundleIDs")
    let saved = defaults.data(forKey: "StashedApps")

    let module = StashModule()
    check(module.store == nil, "init ничего не создаёт и не читает")
    let idle = decodedReply(module.handle(encode(StashAction.restore)))
    check(idle?.error != nil && idle?.state.stashed.isEmpty == true, "до start действия не принимаются, записи он не показывает")
    check(defaults.data(forKey: "StashedApps") == saved, "до start запись не тронута")
    check(module.quickActions.isEmpty, "до start быстрых действий нет")

    module.start()
    let state = try? JSONDecoder().decode(StashState.self, from: module.state())
    check(state?.stashed == [.init(bundleID: "test.closed", name: "Закрытая", windowCount: 2)], "утилита видит запись, сделанную центром: \(String(describing: state?.stashed))")
    check(state?.scenarios == [scenario], "и сценарии")
    check(module.statusLine(passiveReason: nil) == "Спрятано 1 · можно вернуть" && !module.statusLine(passiveReason: nil).contains("Закрытая"),
          "статус: счётчик без имён")
    check(module.quickActions.map(\.title) == ["Вернуть"] && module.quickActions.first.map { $0.action == encode(StashAction.restore) } == true,
          "быстрое действие «Вернуть» — готовый restore")
    check(module.setupSteps.map(\.id) == ["stash.ax"], "шаг Универсального доступа объявлен")

    // Пока модуль стоит, запись меняет центр; после повторного start утилита видит новое.
    module.enterPassive()
    check(module.store == nil, "passive = остановлен")
    let second = StashedApp(bundleID: "test.second", path: "/nonexistent/second.app", name: "Вторая", windows: [])
    defaults.set(try! JSONEncoder().encode([record, second]), forKey: "StashedApps")
    let afterPassive = decodedReply(module.handle(encode(StashAction.restore)))
    check(afterPassive?.error != nil && defaults.data(forKey: "StashedApps") != nil, "в passive действие отвергнуто, запись на месте")
    module.start()
    check((try? JSONDecoder().decode(StashState.self, from: module.state()))?.stashed.map(\.bundleID) == ["test.closed", "test.second"],
          "после повторного start записи прочитаны заново")

    // Запись, которую не прочитать, не пропадает: уходит под отдельный ключ и не стирается пустым списком.
    module.stop()
    let junk = Data("не json".utf8)
    defaults.set(junk, forKey: "StashedApps")
    let idleModule = StashModule()
    check(defaults.data(forKey: "StashedApps") == junk, "созданный и не запущенный модуль нечитаемую запись не трогает")
    idleModule.start()
    check(defaults.data(forKey: "StashedApps.unreadable") == junk, "запущенный откладывает нечитаемую запись, а не теряет")
    idleModule.stop()
    reset()
}

/// Замер памяти идёт только пока экран открыт.
@MainActor func lease() async {
    reset()
    let module = StashModule()
    module.start()
    guard let store = module.store else { check(false, "модуль запущен"); return }
    let ask = encode(StashAction.refreshUsage)

    check(decodedReply(module.handle(ask))?.error == nil && !store.usagePending, "экран закрыт: просьба замерить принята, ps не запущен")
    module.screenOpen(true)
    check(store.usagePending, "экран открылся: замер пошёл сам")
    check(await until(10) { !store.usagePending }, "замер закончился")
    check(decodedReply(module.handle(ask))?.error == nil && store.usagePending, "экран открыт: просьба запускает замер")
    check(decodedReply(module.handle(ask))?.error == nil, "вторая просьба на идущий замер не наслаивается")
    check(await until(10) { !store.usagePending }, "и этот замер закончился")
    module.screenOpen(false)
    check(decodedReply(module.handle(ask))?.error == nil && !store.usagePending, "экран закрыт снова: замера нет")
    module.stop()
    module.screenOpen(true)
    check(module.store == nil, "после stop аренда ничего не оживляет")
    reset()
}

/// Пинги: изменение состояния доходит до хоста.
@MainActor func pings() async {
    reset()
    let module = StashModule()
    var count = 0
    let sub = module.changes.sink { count += 1 }
    module.start()
    Kit.defaults.set(try! JSONEncoder().encode([record]), forKey: "StashedApps")
    module.store?.setClosing("test.x", false)
    check(count > 0, "изменение стеша выдаёт сигнал в changes")
    sub.cancel()
    module.stop()
    reset()
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Любое зависание — провал, а не вечное ожидание.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            print("FAIL проверка не уложилась в 90 с")
            exit(2)
        }
        Task { @MainActor in
            await protection()
            await continuity()
            await lease()
            await pings()
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
