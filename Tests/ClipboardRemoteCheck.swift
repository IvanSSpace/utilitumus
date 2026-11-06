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

/// Утилите кладут выдуманные записи; встроенный экран получает те же. Снимки сравниваются по пикселям.
@MainActor func pixels(utility: Int32) async {
    let model = RemoteClipboardModel.shared
    let modules = ModuleManager.shared
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
    check(ClipboardController.shared.items.count == 6 && ClipboardController.shared.spaces.count == 2, "встроенный экран получил те же записи")

    var shots: [NSBitmapImageRep] = []
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        modules.setExternal(.clipboard, false)
        let builtIn = await Stand.open(theme)
        Stand.save(builtIn, "\(themeName)-local")
        modules.setExternal(.clipboard, true)
        await registry.update()
        check(registry.isEnabled(.clipboard), "\(themeName): реестр видит утилиту включённой")
        let remote = await Stand.open(theme)
        Stand.save(remote, "\(themeName)-remote")
        let diff = differingPixels(builtIn, remote)
        check(diff == 0, "\(themeName): снимки совпали, разных пикселей \(diff) из \(builtIn.pixelsWide * builtIn.pixelsHigh)")
        shots.append(remote)
    }
    check(differingPixels(shots[0], shots[1]) > 0, "две темы выглядят по-разному, снимки не пустые")
    // Записи утилиты с другим пространством выглядят иначе: сравнение что-то различает.
    await model.perform(.deleteSpace(id: model.spaces[0].id))
    await model.read()
    let changed = await Stand.open(.dusk)
    check(differingPixels(shots[0], changed) > 0, "после удаления пространства экран утилиты другой")
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
