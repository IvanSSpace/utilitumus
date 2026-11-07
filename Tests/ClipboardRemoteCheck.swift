import AppKit
import Carbon.HIToolbox
import CryptoKit
import SwiftUI

// Вкладка «Буфер» в лаунчере, работа в утилите. Запуск: Tests/run-clipboard-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Связка ключей только в памяти (`MemoryClipboardKeyring`),
// история во временной папке, буфер обмена утилита не опрашивает (сборка со швом): настоящих данных нет ни на одном шаге.

let moduleID = "test.clipboard"
let fakeKey = Data(repeating: 9, count: 32)
let keyMessage = LinkWire.encoded(ClipboardKeyMessage(key: fakeKey))
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"togglePanel":{},"x":1}"#),
    ("чужой ключ рядом со значением", #"{"setLimit":{"value":250},"x":1}"#),
    ("два действия", #"{"clearHistory":{},"resetHotKey":{}}"#),
    ("чужой ключ внутри togglePanel", #"{"togglePanel":{"x":1}}"#),
    ("действие без значения", #"{"setLimit":{}}"#),
    ("значение не того типа", #"{"setLimit":{"value":"много"}}"#),
    ("не uuid", #"{"deleteSpace":{"id":"не-uuid"}}"#),
    ("пустое имя пространства", #"{"addSpace":{"name":"   ","colorID":"teal"}}"#),
    ("чужой цвет", #"{"addSpace":{"name":"Х","colorID":"нет-такого"}}"#),
    ("повтор ключа", #"{"setLimit":{"value":250},"setLimit":{"value":50}}"#),
]
/// Разбираются как действия, а отказ даёт утилита при исполнении (текст ошибки, состояние то же).
let refusedByUtility: [(String, String)] = [
    ("лимит вне списка", #"{"setLimit":{"value":12345}}"#),
    ("плохой bundle id", #"{"addExcluded":{"bundleID":"плохой id"}}"#),
]

// MARK: - Сценарии

func wirePure() {
    let id = UUID()
    let actions: [ClipboardAction] = [.togglePanel, .clearHistory, .setLimit(value: 250), .addSpace(name: "Новое", colorID: "teal"),
                                      .moveSpace(id: id, by: 1), .setHotKey(keyCode: 9, modifiers: UInt32(cmdKey))]
    for action in actions {
        check(LinkWire.decodeAction(ClipboardAction.self, from: LinkWire.encoded(action), limit: 1024) == action, "ClipboardAction \(action) переживает кодирование")
    }
    for (name, payload) in notOneAction {
        check(LinkWire.decodeAction(ClipboardAction.self, from: Data(payload.utf8), limit: 1024) == nil, "\(name) не разбирается")
    }
    check(LinkWire.decodeAction(ClipboardAction.self, from: keyMessage, limit: 1024) == nil, "передача ключа — не действие экрана")
    check(String(decoding: LinkWire.encoded(ClipboardKeyReply(received: false)),
                 as: UTF8.self) == #"{"received":false}"#, "ответ на передачу не несёт ничего, кроме да/нет")
}

@MainActor func garbage() async {
    await checkBadActions(ClipboardState.self, id: moduleID, extra: (notOneAction + refusedByUtility).map { ($0.0, Data($0.1.utf8)) })
}

/// Утилита ждала ключ; центр передал его сам, из своей памяти, и утилита сама подтвердила.
@MainActor func handover() async {
    let model = RemoteClipboardModel.shared
    await model.read()
    check(await until(15) { model.state.keyState == .ready }, "передача ключа: утилита подтвердила, состояние ready")
    check(model.storeError == nil && model.responding, "передача ключа: ошибки нет, утилита отвечает")
    // Ключ прислали ещё раз: утилита ключ не ждёт, отказ, состояние то же.
    let link = LinkClient(id: moduleID)
    let before = try? await link.moduleState()
    let answer = try? await link.moduleAction(keyMessage)
    check(answer.flatMap { try? JSONDecoder().decode(ClipboardKeyReply.self, from: $0) }?.received == false, "ключ при готовой истории от центра отвергнут")
    let after = try? await link.moduleState()
    check(after == before, "после этого состояние то же, байт в байт")
}

/// Экран утилиты на её контроллере в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.clipboard), animated: false) { _, active in
        AnyView(ModuleScreen(module: .clipboard) { ClipboardView(model: ClipboardController.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.clipboard))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .clipboard, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

/// Утилите кладут выдуманные записи; контроллер утилиты в стенде получает те же. Снимки сравниваются по пикселям.
@MainActor func pixels(utility: Int32) async {
    let model = RemoteClipboardModel.shared
    let registry = SatelliteRegistry.shared
    kill(utility, SIGUSR1)
    // Утилита сообщает о записях только тому, кто смотрит на экран; стенд читает сам, пока записи не придут.
    var seeded = false
    for _ in 0..<50 {
        await model.read()
        if model.totalCount == 6 { seeded = true; break }
        await pause(0.1)
    }
    check(seeded, "утилита приняла выдуманные записи: 6")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstand-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = ClipboardStore(directory: directory, key: SymmetricKey(size: .bits256))
    ClipboardStandFixture.seed(local)
    ClipboardController.shared.attach(local)
    check(ClipboardController.shared.axTrusted == model.axTrusted, "разрешение Универсального доступа у центра и утилиты одно: иначе пиксели разойдутся")
    check(ClipboardController.shared.items.count == 6 && ClipboardController.shared.spaces.count == 2, "контроллер утилиты получил те же записи")
    // Доступа в стенде нет: без «Позже» на месте экрана мог бы быть чек-лист, и сверялись бы два чек-листа.
    await registry.update()
    SetupFlow.shared.postpone(.clipboard)

    var shots: [NSBitmapImageRep] = []
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        let screen = await openLocal(theme)
        Stand.save(screen, "\(themeName)-local")
        await registry.update()
        check(registry.isEnabled(.clipboard), "\(themeName): реестр видит утилиту включённой")
        let remote = await Stand.open(theme)
        Stand.save(remote, "\(themeName)-remote")
        let diff = differingPixels(screen, remote)
        check(diff == 0, "\(themeName): снимки совпали, разных пикселей \(diff) из \(screen.pixelsWide * screen.pixelsHigh)")
        shots.append(remote)
    }
    check(differingPixels(shots[0], shots[1]) > 0, "две темы выглядят по-разному, снимки не пустые")
    // Сверка видит записи: контроллер без них на снимок вкладки не похож.
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    ClipboardController.shared.attach(ClipboardStore(directory: directory.appendingPathComponent("empty"), key: SymmetricKey(size: .bits256)))
    let emptied = await openLocal(.dusk)
    Stand.save(emptied, "dusk-empty-local")
    check(differingPixels(emptied, shots[0]) > 0, "контроллер без записей сверка замечает: разных пикселей \(differingPixels(emptied, shots[0]))")
    await dragSpacesOnTab()
    // Записи утилиты с другим пространством выглядят иначе: сравнение что-то различает.
    await model.perform(.deleteSpace(id: model.spaces[0].id))
    await model.read()
    let changed = await Stand.open(.dusk)
    check(differingPixels(shots[0], changed) > 0, "после удаления пространства экран утилиты другой")
}

/// Строка вкладки центра, настоящие события мыши, настоящая связка: бросок доходит до утилиты прежним `moveSpace`.
@MainActor func dragSpacesOnTab() async {
    let model = RemoteClipboardModel.shared
    await model.read()
    let names = model.spaces.map(\.name)
    guard names.count >= 2 else { return check(false, "у утилиты два пространства (\(names))") }
    let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ClipboardView(model: model).environment(\.dsTheme, DSTheme.dusk).frame(width: 738, height: 660))
    host.frame = NSRect(x: 0, y: 0, width: 738, height: 660)
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    await pause(0.5)
    host.layoutSubtreeIfNeeded()
    func field(_ name: String) -> NSRect? {
        func walk(_ view: NSView) -> NSRect? {
            if let text = view as? NSTextField, text.stringValue == name { return text.convert(text.bounds, to: nil) }
            return view.subviews.lazy.compactMap(walk).first
        }
        return walk(host)
    }
    guard let a = field(names[0]), let b = field(names[1]) else { return check(false, "строки пространств на вкладке") }
    func send(_ type: NSEvent.EventType, _ p: NSPoint) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    let start = NSPoint(x: a.minX + 30, y: a.midY), end = NSPoint(x: a.minX + 30, y: b.midY)
    send(.leftMouseDown, start)
    send(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 10))
    await pause(0.05)
    send(.leftMouseDragged, end)
    await pause(0.2)
    send(.leftMouseUp, end)
    let expected = [names[1], names[0]] + names.dropFirst(2)
    check(await until(5) {
        await model.read()
        return model.spaces.map(\.name) == expected
    }, "вкладка центра: перенос строки дошёл до утилиты: \(model.spaces.map(\.name))")
    await pause(0.3)
    // Обратно, чтобы дальше сверка шла как раньше.
    await model.perform(.moveSpace(id: model.spaces[0].id, by: 1))
    await model.read()
}

/// Утилита умерла: центр это видит, запасной экран, процесс не поднимается заново сам (KeepAlive выключен).
@MainActor func death(utility: Int32) async {
    let model = RemoteClipboardModel.shared
    let registry = SatelliteRegistry.shared
    let known = await Stand.open(.dusk)
    killUtilityForGood(utility)
    await model.read()
    await model.read()
    check(!model.responding, "утилита умерла: модель это увидела")
    check(await until(5) { registry.entries[.clipboard]?.status == nil }, "утилита умерла: реестр тоже")
    let shot = await Stand.open(.dusk)
    Stand.save(shot, "dusk-dead")
    check(differingPixels(known, shot) > 0, "утилита умерла: виден запасной экран")
}

/// Роли отдельных процессов: копия утилиты из Finder и пассивная утилита.
@MainActor func lone(_ role: String) async {
    let link = LinkClient(id: moduleID)
    switch role {
    case "own-copy":
        // Процесс с identifier самой утилиты: служба центра его не пускает, ни состояния, ни ключа он получить не может.
        var stateRefused = false, actionRefused = false
        do { _ = try await link.moduleState() } catch { stateRefused = true }
        do { _ = try await link.moduleAction(keyMessage) } catch { actionRefused = true }
        print("stateRefused=\(stateRefused) actionRefused=\(actionRefused)")
        exit(stateRefused && actionRefused ? 0 : 3)
    case "passive":
        do {
            let status = try await link.status()
            let state = try JSONDecoder().decode(ClipboardState.self, from: await link.moduleState())
            let before = try await link.moduleState()
            let reply = try JSONDecoder().decode(LinkReply<ClipboardState>.self,
                                                 from: await link.moduleAction(LinkWire.encoded(ClipboardAction.addSpace(name: "Х", colorID: "teal"))))
            let keyAnswer = try JSONDecoder().decode(ClipboardKeyReply.self, from: await link.moduleAction(keyMessage))
            let after = try await link.moduleState()
            check(status.line == "Ждём передачу от центра", "пассивная: строка статуса «\(status.line)»")
            check(state.keyState == nil && state.totalCount == 0 && state.spaces.isEmpty, "пассивная: хранилища нет, ключ не читался")
            check(reply.error != nil && reply.state.spaces.isEmpty, "пассивная: действие отвергнуто («\(reply.error ?? "нет")»)")
            check(!keyAnswer.received, "пассивная: ключ не принят даже от центра")
            check(before == after, "пассивная: состояние не изменилось")
            check(status.quickActions.isEmpty, "пассивная: быстрых действий нет")
            finish()
        } catch {
            check(false, "пассивная: \(error)")
            finish()
        }
    default:
        fatalError("неизвестная роль")
    }
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        if let role = CommandLine.arguments.dropFirst().first, role == "own-copy" || role == "passive" {
            Task { @MainActor in await lone(role) }
            dispatchMain()
        }
        MainActor.assumeIsolated {
            ModuleCheck.main(.clipboard, foreignAction: keyMessage) { utility in
                wirePure()
                await garbage()
                await handover()
                await pixels(utility: utility)
                await death(utility: utility)
            }
        }
    }
}
