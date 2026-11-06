import AppKit
import SwiftUI

// Вкладка «Мышь» в лаунчере, работа в утилите. Запуск: Tests/run-mouse-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Настоящий tap на прокрутку не создаётся: шов KIT_TEST_DEFAULTS.

let moduleID = "test.mouse"
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"refreshAccess":{},"x":1}"#),
    ("чужой ключ рядом со значением", #"{"setSpeed":{"_0":1.5},"x":1}"#),
    ("два действия", #"{"refreshAccess":{},"requestAccess":{}}"#),
    ("чужой ключ внутри", #"{"setSmoothEnabled":{"_0":true,"x":1}}"#),
    ("действие без значения", #"{"setSpeed":{}}"#),
    ("значение не того типа", #"{"setSmoothEnabled":{"_0":1}}"#),
    ("нет такого направления", #"{"setMouseDirection":{"_0":"sideways"}}"#),
    ("скорость не число", #"{"setSpeed":{"_0":"nan"}}"#),
    ("скорость больше Double", #"{"setSpeed":{"_0":1e999}}"#),
    ("повтор ключа", #"{"setSpeed":{"_0":1.5},"setSpeed":{"_0":3}}"#),
]

struct MouseCase {
    let name: String
    let settings: MouseSettings
}

let scenes: [MouseCase] = [
    MouseCase(name: "as-system", settings: MouseSettings()),
    MouseCase(name: "reversed", settings: MouseSettings(mouseDirection: .reversed)),
    MouseCase(name: "smooth", settings: MouseSettings(magicMouseDirection: .reversed, smoothEnabled: true, speed: 2.3, smoothness: 0.7)),
]

/// Настоящая утилита приходит в состояние через модель центра, по одному полю.
@MainActor func drive(_ settings: MouseSettings) async {
    let model = RemoteMouseModel.shared
    await model.perform(.setMouseDirection(settings.mouseDirection))
    await model.perform(.setMagicMouseDirection(settings.magicMouseDirection))
    await model.perform(.setSmoothEnabled(settings.smoothEnabled))
    await model.perform(.setSpeed(settings.speed))
    await model.perform(.setSmoothness(settings.smoothness))
    await model.read()
}

@MainActor func garbage() async {
    await checkBadActions(MouseState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) })
}

@MainActor func settingsViaModel() async {
    let model = RemoteMouseModel.shared
    await drive(MouseSettings())
    check(model.responding && model.settings == MouseSettings(), "утилита отвечает, настройки по умолчанию")
    // Привязки экрана пишут в settings целиком: уходит только изменённое поле.
    model.settings.smoothEnabled = true
    check(model.settings.smoothEnabled, "переключатель показан сразу, до ответа утилиты")
    await model.read()
    check(await until(2) { model.state.settings.smoothEnabled }, "переключатель подтвердила утилита")

    let truth = LinkClient(id: moduleID)
    await model.perform(.setSpeed(100))
    check(model.settings.speed == 3.0, "скорость 100 ограничена до 3")
    let saved = try? JSONDecoder().decode(MouseState.self, from: await truth.moduleState())
    check(saved?.settings.speed == 3.0, "утилита хранит 3, а не 100")
    await model.perform(.setSpeed(.nan))
    check(model.actionError != nil && model.settings.speed == 3.0, "NaN: отказ с текстом, скорость прежняя")

    // Ползунок шлёт много значений подряд: в итоге остаётся последнее.
    for step in 1...20 { model.settings.smoothness = Double(step) / 20 }
    await model.read()
    let last = try? JSONDecoder().decode(MouseState.self, from: await truth.moduleState())
    check(await until(3) { model.state.settings.smoothness == 1 }, "ползунок: центр показывает последнее значение")
    check(last != nil, "состояние читается после серии значений")
    await drive(MouseSettings())
}

@MainActor func pixels() async {
    let model = RemoteMouseModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    let controller = MouseController.shared

    /// Страница как первое открытие вкладки; при открытии экран просит свежий доступ, поэтому состояние ставится после.
    func shot(_ theme: DSTheme, pin: (() -> Void)?) async -> NSBitmapImageRep {
        let container = Stand.container()
        container.show(.module(.mouse), animated: false, make: Stand.page(theme))
        await pause(0.4)
        pin?()
        await pause(0.2)
        return Stand.snapshot(container)
    }

    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        // Экран доступа вместо настроек: у него от настроек ничего не зависит, два таких снимка совпадают.
        var shots: [(image: NSBitmapImageRep, checklist: Bool)] = []
        for scene in scenes {
            await drive(scene.settings)
            check(model.responding && model.settings == scene.settings, "\(themeName) \(scene.name): утилита в нужном состоянии")
            let ax = model.axTrusted

            modules.setExternal(.mouse, false)
            controller.settings = scene.settings
            // Шаг доступа у встроенного модуля читает права самого центра, у утилиты — её права: на стенде они разные.
            // Подменяем шаг тем, что описал бы модуль утилиты: обязателен при перехвате, готов по закреплённому доступу.
            SetupFlow.overrides[.mouse] = [SetupStep(id: "mouse.ax", title: "Универсальный доступ",
                                                     why: "Чтобы менять направление и плавность прокрутки",
                                                     kind: .permission, icon: "lock.shield.fill",
                                                     required: scene.settings.needsTap, isDone: { ax }, perform: {})]
            AccessState.shared.refresh()
            let local = await shot(theme) { controller.testPin(axTrusted: ax, tapActive: false) }
            SetupFlow.overrides[.mouse] = nil
            AccessState.shared.refresh()
            Stand.save(local, "\(themeName)-\(scene.name)-local")

            modules.setExternal(.mouse, true)
            await registry.update()
            check(registry.isEnabled(.mouse), "\(themeName) \(scene.name): реестр видит утилиту включённой")
            let remote = await shot(theme, pin: nil)
            Stand.save(remote, "\(themeName)-\(scene.name)-remote")

            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(scene.name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append((remote, scene.settings.needsTap && !ax))
        }
        check(zip(shots, shots.dropFirst()).allSatisfy { ($0.checklist && $1.checklist) || differingPixels($0.image, $1.image) > 0 },
              "\(themeName): состояния выглядят по-разному, снимки не пустые")
        await drive(MouseSettings())
    }
    controller.settings = MouseSettings()
}

/// Статус и шаг доступа утилиты видит центр без экрана модуля.
@MainActor func status() async {
    let registry = SatelliteRegistry.shared
    let model = RemoteMouseModel.shared
    await drive(MouseSettings())
    await registry.update()
    var steps = registry.entries[.mouse]?.status?.setupSteps ?? []
    check(steps.map(\.id) == ["mouse.ax"] && steps[0].required == false, "настройки по умолчанию: шаг доступа есть и необязателен")
    check(registry.entries[.mouse]?.status?.line == "всё как в системе", "строка статуса «\(registry.entries[.mouse]?.status?.line ?? "нет")»")
    await model.perform(.setMouseDirection(.reversed))
    await registry.update()
    steps = registry.entries[.mouse]?.status?.setupSteps ?? []
    check(steps.first?.required == true, "обратная прокрутка: шаг доступа обязателен")
    await drive(MouseSettings())
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteMouseModel.shared
    await model.read()
    let before = model.state
    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setSmoothEnabled(!before.settings.smoothEnabled))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 2.5, String(format: "зависшая утилита: действие сдалось за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "зависшая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    check(model.state == before, "зависшая утилита: прежнее состояние")
    check(model.actionError != nil, "зависшая утилита: короткий текст «\(model.actionError ?? "нет")»")
    kill(utility, SIGCONT)
    await pause(0.5)
    await model.read()
    await model.perform(.setSmoothEnabled(false))
    await model.read()
    check(model.actionError == nil && model.responding, "после разморозки ошибок нет")
}

/// Утилита умерла: центр говорит «не отвечает», а не показывает старое как живое.
@MainActor func died(utility: Int32) async {
    let model = RemoteMouseModel.shared
    killUtilityForGood(utility)
    await pause(0.3)
    await model.read()
    await model.read()
    check(await until(5) { !model.responding }, "утилита убита: модель «не отвечает»")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.mouse, foreignAction: LinkWire.encoded(MouseAction.setSmoothEnabled(true))) { utility in
                await garbage()
                await settingsViaModel()
                await pixels()
                await status()
                await hung(utility: utility)
                await died(utility: utility)
                check(!MouseController.shared.testIsRunning, "за весь прогон встроенный контроллер у центра не запускался")
            }
        }
    }
}
