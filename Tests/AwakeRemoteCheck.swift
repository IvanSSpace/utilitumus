import AppKit
import SwiftUI

// Вкладка «Не спать» в лаунчере, работа в утилите. Запуск: Tests/run-awake-remote-check.sh
// Стенд собирается из всех исходников центра со швом KIT_TEST_DEFAULTS, рисует настоящий `ModuleDetail` через
// настоящий `PageContainer`, окно за экраном и прозрачное, снимки через cacheDisplay. Утилита настоящая, под launchd.
// Роли: run <папка> <pid утилиты>, foreign, state, idle <папка>.

let moduleID = "test.awake"
let assertionName = "Utilitumus: Keep Awake"
let unknownAction = #"{"explode":{}}"#
let badDuration = #"{"setDuration":{"_0":12345}}"#
/// Не одно известное действие: разбор отказывает, сколько бы известного в этом ни было.
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"toggle":{},"x":1}"#),
    ("чужой ключ рядом со значением", #"{"setDuration":{"_0":3600},"x":1}"#),
    ("два действия", #"{"toggle":{},"setKeepDisplay":{"_0":true}}"#),
    ("чужой ключ внутри toggle", #"{"toggle":{"x":1}}"#),
    ("чужой ключ внутри действия", #"{"setKeepDisplay":{"_0":true,"x":1}}"#),
    ("действие без значения", #"{"setDuration":{}}"#),
    ("значение не того типа", #"{"setKeepDisplay":{"_0":1}}"#),
    ("toggle не объект", #"{"toggle":1}"#),
    ("пустой объект", "{}"),
    ("массив", #"[{"toggle":{}}]"#),
]
let repeatedKey = #"{"setDuration":{"_0":3600},"setDuration":{"_0":0}}"#

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Как `Tests/LinkCheck.swift`: насколько надолго занят главный поток.
@MainActor final class TickWatch {
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maxGap = 0.0
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.maxGap = max(self.maxGap, now - self.last)
                self.last = now
            }
        }
    }
    deinit { timer?.invalidate() }
}

/// Не на главном потоке: стенд измеряет его простой.
func holdsAssertion(pid: Int32) async -> Bool {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .contains { $0.contains(assertionName) && $0.contains("pid \(pid)(") }
    }.value
}

// MARK: - Окно и снимки

@MainActor enum Stand {
    static var out = ""

    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Корень страницы как в `MainView`: окружение задаётся на странице, через границу хостинга оно не проходит.
    static func page(_ theme: DSTheme) -> (PageKey, Bool) -> AnyView {
        { key, active in
            guard case .module(let module) = key else { return AnyView(Color.black) }
            return AnyView(ModuleDetail(module: module)
                .environment(\.pageActive, active)
                .environment(\.dsTint, theme.accent(module))
                .environment(\.moduleControls, DSModuleControls.forEnvironment)
                // Подложка как в окне: фон модуля и карточка страницы, иначе снимок полупрозрачный.
                .background(ZStack { DSBackground(module: module, neutral: false); theme.card })
                .dsThemed()
                .ignoresSafeArea())
        }
    }

    static func container() -> PageContainer {
        let container = PageContainer(frame: NSRect(x: 0, y: 0, width: 738, height: 660))
        window.contentView = container
        return container
    }

    /// Новая страница: как первое открытие вкладки.
    static func open(_ theme: DSTheme) async -> NSBitmapImageRep {
        let container = container()
        container.show(.module(.awake), animated: false, make: page(theme))
        await pause(0.5)
        return snapshot(container)
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, _ name: String) {
        let path = out + "/png/" + name + ".png"
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Сколько пикселей отличается; размер не совпал — все.
func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData else {
        return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh)
    }
    let pixelBytes = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let offset = y * a.bytesPerRow + x * pixelBytes
            if memcmp(pa + offset, pb + offset, pixelBytes) != 0 { count += 1 }
        }
    }
    return count
}

// MARK: - Состояния

struct Pinned {
    let name: String
    let active: Bool
    let duration: AwakeDuration
    let keepDisplay: Bool
}

let pinnedStates = [
    Pinned(name: "sleeps", active: false, duration: .forever, keepDisplay: false),
    Pinned(name: "awake-forever", active: true, duration: .forever, keepDisplay: false),
    Pinned(name: "awake-1h", active: true, duration: .hour1, keepDisplay: true),
]

/// Настоящая утилита приходит в состояние через модель центра.
@MainActor func drive(_ pinned: Pinned) async {
    let model = RemoteAwakeModel.shared
    if model.isActive { await model.perform(.toggle) }
    await model.perform(.setDuration(pinned.duration.rawValue))
    await model.perform(.setKeepDisplay(pinned.keepDisplay))
    if pinned.active { await model.perform(.toggle) }
}

/// Встроенный контроллер в том же состоянии, тот же срок до секунды. Assertion у стенда при этом не появляется.
@MainActor func pinLocal(to state: AwakeState) {
    let controller = AwakeController.shared
    controller.testPin(isActive: false, endDate: nil)
    controller.keepDisplay = state.keepDisplay
    controller.duration = state.duration
    controller.canStart = state.canStart
    controller.testPin(isActive: state.isActive, endDate: state.endDate)
}

@MainActor func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { await pause(0.02) }
    return condition()
}

// MARK: - Сценарии

func wirePure() {
    let state = AwakeState(isActive: true, endDate: Date(timeIntervalSinceReferenceDate: 800_000_000.25), keepDisplay: true,
                           duration: .hour2, canStart: false)
    check((try? JSONDecoder().decode(AwakeState.self, from: JSONEncoder().encode(state))) == state, "AwakeState переживает кодирование, срок до доли секунды")
    let actions: [AwakeAction] = [.toggle, .setKeepDisplay(true), .setDuration(3600)]
    for action in actions {
        check((try? JSONDecoder().decode(AwakeAction.self, from: JSONEncoder().encode(action))) == action, "AwakeAction \(action) переживает кодирование")
    }
    let foreign = #"{"isActive":false,"keepDisplay":false,"duration":12345,"canStart":true}"#
    check((try? JSONDecoder().decode(AwakeState.self, from: Data(foreign.utf8))) == nil, "состояние с чужой длительностью центр не принимает")
    check((try? JSONDecoder().decode(AwakeAction.self, from: Data(unknownAction.utf8))) == nil, "неизвестное действие не разбирается")
    for (name, payload) in notOneAction {
        check((try? JSONDecoder().decode(AwakeAction.self, from: Data(payload.utf8))) == nil, "\(name) не разбирается: \(payload)")
    }
}

/// Мусор доходит до утилиты: ответ — ошибка, состояние то же байт в байт.
@MainActor func garbage() async {
    let link = LinkClient(id: moduleID)
    guard let before = try? await link.moduleState() else { return check(false, "мусор: состояние не прочитано") }
    let cases: [(String, Data)] = [
        ("мусор", Data("{не json".utf8)),
        ("пустое", Data()),
        ("неизвестное действие", Data(unknownAction.utf8)),
        ("длительность 12345", Data(badDuration.utf8)),
        ("повтор ключа", Data(repeatedKey.utf8)),
    ] + notOneAction.map { ($0.0, Data($0.1.utf8)) } + [
        ("слишком длинное", Data(#"{"toggle":{}, "x":""#.utf8) + Data(repeating: 0x61, count: 100_000) + Data(#""}"#.utf8)),
    ]
    for (name, payload) in cases {
        do {
            let data = try await link.moduleAction(payload)
            let reply = try JSONDecoder().decode(AwakeReply.self, from: data)
            check(reply.error != nil, "\(name): ошибка («\(reply.error ?? "нет")»)")
            check(try JSONDecoder().decode(AwakeState.self, from: before) == reply.state, "\(name): в ответе прежнее состояние")
        } catch {
            check(false, "\(name): \(error)")
        }
        // Значения, не байты: JSONEncoder от раза к разу меняет порядок ключей.
        let decode = { (data: Data?) in data.flatMap { try? JSONDecoder().decode(AwakeState.self, from: $0) } }
        let after = try? await link.moduleState()
        check(decode(after) != nil && decode(after) == decode(before), "\(name): состояние не изменилось")
    }
}

@MainActor func button(stand: Int32, utility: Int32) async {
    let model = RemoteAwakeModel.shared
    await model.read()
    check(model.responding && !model.isActive, "до нажатия блокировки нет")
    check(!(await holdsAssertion(pid: utility)), "до нажатия assertion нет")
    model.toggle()
    check(await until(2) { model.isActive }, "нажатие: модель показала ответ утилиты")
    check(await holdsAssertion(pid: utility), "нажатие: assertion у процесса утилиты")
    check(!(await holdsAssertion(pid: stand)), "нажатие: у центра assertion нет")
    check(!AwakeController.shared.isActive, "нажатие: встроенный контроллер не трогали")

    // Статус меняет сама утилита: команда сигналом, чтения от стенда нет.
    kill(utility, SIGUSR1)
    check(await until(2) { !model.isActive }, "statusChanged: центр перечитал и увидел выключение")
    check(!(await holdsAssertion(pid: utility)), "повторное нажатие снимает assertion")

    await model.perform(.setDuration(12345))
    check(model.actionError != nil && model.duration == .forever, "длительность 12345 через модель: текст ошибки, длительность прежняя")
    await model.perform(.setDuration(7200))
    check(model.actionError == nil && model.duration == .hour2, "успешное действие убирает текст ошибки")
    let other = LinkClient(id: moduleID)
    _ = try? await other.moduleAction(try! JSONEncoder().encode(AwakeAction.setDuration(0)))
    check(await until(2) { model.duration == .forever }, "настройку поменяли снаружи: центр увидел по statusChanged")
    _ = try? await other.moduleAction(try! JSONEncoder().encode(AwakeAction.setKeepDisplay(true)))
    check(await until(2) { model.keepDisplay }, "и «экран не гаснет» тоже")
    await model.perform(.setKeepDisplay(false))

    // Выключенная утилита не включает блокировку, что бы ни прислали.
    try? await other.setEnabled(false)
    check(await until(2) { !model.canStart }, "утилита выключена: canStart снят")
    await model.perform(.toggle)
    check(model.actionError != nil && !model.isActive, "утилита выключена: действие отвергнуто с текстом")
    check(!(await holdsAssertion(pid: utility)), "утилита выключена: assertion нет")
    try? await other.setEnabled(true)
    check(await until(2) { model.canStart }, "утилита снова включена")
}

@MainActor func pixels() async {
    let model = RemoteAwakeModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for pinned in pinnedStates {
            await drive(pinned)
            await model.read()
            check(model.responding && model.isActive == pinned.active && model.duration == pinned.duration, "\(themeName) \(pinned.name): утилита в нужном состоянии")
            check((model.endDate != nil) == (pinned.duration != .forever && pinned.active), "\(themeName) \(pinned.name): срок \(model.endDate.map(String.init(describing:)) ?? "нет")")

            modules.setExternal(.awake, false)
            pinLocal(to: model.state)
            let local = await Stand.open(theme)
            Stand.save(local, "\(themeName)-\(pinned.name)-local")

            modules.setExternal(.awake, true)
            await registry.update()
            check(registry.isEnabled(.awake), "\(themeName) \(pinned.name): реестр видит утилиту включённой")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(pinned.name)-remote")

            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(pinned.name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append(remote)
        }
        check(differingPixels(shots[0], shots[1]) > 0 && differingPixels(shots[1], shots[2]) > 0, "\(themeName): три состояния выглядят по-разному, снимки не пустые")
        await drive(pinnedStates[0])
    }
    // Эта тема выбрана и выключенный модуль выглядит как встроенный выключенный.
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    let other = LinkClient(id: moduleID)
    modules.setOn(.awake, false)
    modules.setExternal(.awake, false)
    let local = await Stand.open(.dusk)
    Stand.save(local, "dusk-off-local")
    modules.setOn(.awake, true)
    modules.setExternal(.awake, true)
    try? await other.setEnabled(false)
    await registry.update()
    let remote = await Stand.open(.dusk)
    Stand.save(remote, "dusk-off-remote")
    let diff = differingPixels(local, remote)
    check(diff == 0, "выключенный модуль: снимки совпали, разных пикселей \(diff)")
    try? await other.setEnabled(true)
    await registry.update()
    await model.read()
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteAwakeModel.shared
    await model.read()
    let before = model.state
    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setKeepDisplay(!before.keepDisplay))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 2.5, String(format: "зависшая утилита: действие сдалось за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "зависшая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    check(model.state == before, "зависшая утилита: прежнее состояние")
    check(model.actionError != nil, "зависшая утилита: короткий текст «\(model.actionError ?? "нет")»")
    let hungOpen = await Stand.open(.dusk)
    Stand.save(hungOpen, "dusk-action-failed")
    kill(utility, SIGCONT)
    // Сообщение могло дойти после разморозки: тогда утилита объявит об изменении, и центр покажет правду.
    await pause(0.5)
    let truth = LinkClient(id: moduleID)
    let fresh = try? await JSONDecoder().decode(AwakeState.self, from: truth.moduleState())
    check(await until(2) { fresh != nil && model.state == fresh }, "после разморозки центр показывает то же, что утилита")
    await model.perform(.setKeepDisplay(false))
    await model.read()
    check(model.actionError == nil && model.responding, "после разморозки ошибок нет")
}

/// Вкладка открывается мгновенно: ответа утилиты страница не ждёт, ни на кэшированном, ни на новом хосте.
@MainActor func tabs(utility: Int32) async {
    let model = RemoteAwakeModel.shared
    let registry = SatelliteRegistry.shared
    await drive(pinnedStates[1])
    await model.read()
    await registry.update()
    let make = Stand.page(.dusk)
    let warm = Stand.container()
    warm.show(.module(.awake), animated: false, make: make)
    await pause(0.5)
    let known = Stand.snapshot(warm)
    warm.show(.about, animated: false, make: make)
    await pause(0.3)

    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    var started = ProcessInfo.processInfo.systemUptime
    warm.show(.module(.awake), animated: false, make: make)
    var shot = Stand.snapshot(warm)
    var elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 0.3, String(format: "кэш страниц: вкладка показана за %.3f с при зависшей утилите", elapsed))
    check(differingPixels(known, shot) == 0, "кэш страниц: последнее известное состояние, снимок совпал (\(differingPixels(known, shot)))")

    let cold = Stand.container()
    started = ProcessInfo.processInfo.systemUptime
    cold.show(.module(.awake), animated: false, make: make)
    await pause(0.25)
    shot = Stand.snapshot(cold)
    elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 1, String(format: "новая страница: показана за %.3f с при зависшей утилите", elapsed))
    check(differingPixels(known, shot) == 0, "новая страница: последнее известное состояние, снимок совпал (\(differingPixels(known, shot)))")
    check(model.responding, "пока срок не вышел, запасной экран не показан")
    print(String(format: "     сборка новой страницы и снимок заняли главный поток на %.3f с: debug-сборка, связь тут ни при чём", ticks.maxGap))

    // Сборка страницы и снимки стенда позади: теперь главный поток только ждёт ответа.
    let waiting = TickWatch()
    // Срок чтения и опрос реестра выходят: только теперь запасной экран.
    check(await until(2.5) { !model.responding }, "утилита не отвечает: модель это увидела")
    check(await until(2.5) { registry.entries[.awake]?.status == nil }, "и реестр тоже")
    await pause(0.3)
    check(waiting.maxGap <= 0.3, String(format: "ожидание зависшей утилиты и смена экрана: простой главного потока %.3f с, не больше 0,3", waiting.maxGap))
    shot = Stand.snapshot(cold)
    Stand.save(shot, "dusk-not-responding")
    check(differingPixels(known, shot) > 0, "не отвечает: запасной экран виден")

    kill(utility, SIGCONT)
    // Ушли со вкладки и вернулись: страница перечитала и снова показывает экран модуля.
    cold.show(.about, animated: false, make: make)
    await pause(0.1)
    cold.show(.module(.awake), animated: false, make: make)
    check(await until(3) { model.responding }, "утилита ожила: при открытии вкладки экран модуля вернулся")
    await registry.update()
    await pause(0.5)
    check(differingPixels(known, Stand.snapshot(cold)) == 0, "экран модуля снова как был")
    await drive(pinnedStates[0])
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Иначе ModuleManager принял бы пустой домен за обновление и выключил модули.
        UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
        UserDefaults.standard.set(true, forKey: ModuleManager.onKey(.awake))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            switch args[1] {
            case "run":
                await run(out: args[2], utility: Int32(args[3])!)
            case "foreign":
                do {
                    _ = try await LinkClient(id: moduleID).moduleAction(JSONEncoder().encode(AwakeAction.toggle))
                    print("прошло")
                    exit(0)
                } catch {
                    print("отказ: \(error)")
                    exit(3)
                }
            case "state":
                // С упорядоченными ключами: скрипт сравнивает строки, а JSONEncoder от раза к разу меняет порядок.
                let data = (try? await LinkClient(id: moduleID).moduleState()) ?? Data()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let state = try? JSONDecoder().decode(AwakeState.self, from: data)
                print(state.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "")
                exit(0)
            case "idle":
                await idle(out: args[2])
            default:
                fatalError("неизвестная роль")
            }
        }
        app.run()
    }

    @MainActor static func environment(out: String) {
        let link = { @MainActor @Sendable () in LinkClient(id: moduleID) }
        SatelliteRegistry.standEnvironment = SatelliteEnvironment(
            paths: SatellitePaths(appsDir: URL(fileURLWithPath: out), agentsDir: URL(fileURLWithPath: out + "/agents")),
            defaults: Kit.defaults,
            installer: SatelliteInstaller(paths: SatellitePaths(appsDir: URL(fileURLWithPath: out), agentsDir: URL(fileURLWithPath: out + "/agents")),
                                          launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
            commands: SatelliteCommands(
                status: { _ in try await link().status() },
                setEnabled: { _, on in try await link().setEnabled(on) },
                openWindow: { _ in }),
            loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
            hubVersion: "0.6.0",
            modules: .shared)
        Kit.defaults.set(true, forKey: ModuleHandover.handedOverKey(Module.awake.rawValue))
        ModuleManager.shared.setExternal(.awake, true)
    }

    @MainActor static func run(out: String, utility: Int32) async {
        Stand.out = out
        environment(out: out)
        wirePure()
        await garbage()
        await button(stand: getpid(), utility: utility)
        await pixels()
        await hung(utility: utility)
        await tabs(utility: utility)
        check(!(await holdsAssertion(pid: getpid())), "за весь прогон у центра assertion не появился")
        finish()
    }

    /// Простой для замера: вкладка открыта, ничего не происходит.
    @MainActor static func idle(out: String) async {
        Stand.out = out
        environment(out: out)
        await SatelliteRegistry.shared.update()
        _ = await Stand.open(.dusk)
        print("готов")
        fflush(stdout)
    }
}
