import AppKit
import SwiftUI
import Combine

// «Голос»: состояние и действия, отказы, режим проверки, экран за кадром. Запуск: Tests/run-voice-wire-check.sh
// Микрофон, горячая клавиша, вставка, запрос разрешений и сеть не задействованы: start() и requestAccessibility()
// здесь не вызываются. Модели только в подменённом домашнем каталоге, папку настроек задаёт имя процесса.
// Роли: shots <папка> — снимки встроенного экрана (собирается и из старых исходников, VOICE_WIRE_BASE);
// run <папка> — всё остальное.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    cleanSettings()
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
func refuse(_ text: String) -> Never {
    print("ПРОВАЛ: \(text)")
    exit(1)
}

/// Контроллер пишет в `.standard` или, после замены, в `Kit.defaults`: чистим ключи модуля в обоих.
func cleanSettings() {
    for defaults in [UserDefaults.standard, Kit.defaults] {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("Voice.") {
            defaults.removeObject(forKey: key)
        }
    }
}

/// До первого обращения к `VoiceModelStore.shared`: его init чистит папку моделей.
func prepareModels() {
    // Система может отдать путь без /private.
    func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path }
    guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty,
          plain(VoiceModelStore.modelsRoot.path).hasPrefix(plain(home) + "/") else {
        refuse("папка моделей не подменена: \(VoiceModelStore.modelsRoot.path)")
    }
    // Без bundle id `.standard` — домен по имени процесса, скрипт его удаляет.
    guard Bundle.main.bundleIdentifier == nil else { refuse("у процесса есть bundle id: настройки не тестовые") }
    for model in VoiceModel.allCases {
        let folder = VoiceModelStore.folder(of: model)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in model.requiredFiles {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: nil)
        }
    }
}

@MainActor func pause(_ seconds: Double = 0.4) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Окно и снимки

@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Окружение как у страницы в окне, тема задана прямо: общий suite стендов не участвует.
    static func show(_ view: some View, _ theme: DSTheme) -> NSView {
        let host = NSHostingView(rootView: AnyView(view
            .environment(\.pageActive, true)
            .environment(\.dsTint, theme.accent(.voice))
            .environment(\.dsTheme, theme)
            .background(ZStack { DSBackground(module: .voice, neutral: false); theme.card })
            .preferredColorScheme(.dark)
            .ignoresSafeArea()))
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 660)
        window.contentView = host
        return host
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
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
        for x in 0..<a.pixelsWide {
            let offset = y * a.bytesPerRow + x * pixelBytes
            if memcmp(pa + offset, pb + offset, pixelBytes) != 0 { count += 1 }
        }
    }
    return count
}

// MARK: - Встроенный экран: снимки до и после правки

/// Один экран на тему, состояние меняется на живом экране: снимок заодно проверяет перерисовку от обоих объектов.
@MainActor func shots(_ dir: String) async {
    let controller = VoiceController.shared
    let store = VoiceModelStore.shared
    var log = ""
    func shot(_ host: NSView, _ name: String) async {
        await pause()
        let bitmap = Stand.snapshot(host)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        log += "\(name) selected=\(store.selected.rawValue) label=\(controller.hotKeyLabel) mode=\(controller.mode.rawValue)\n"
    }
    func base() {
        store.selected = .gigaam
        controller.mode = .toggle
        controller.micUID = nil
        controller.resetHotKey()
        for id in controller.excludedApps { controller.removeExcluded(id) }
    }
    for (name, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        base()
        let host = Stand.show(VoiceView(), theme)
        await shot(host, "\(name)-both-gigaam")
        store.selected = .parakeet
        await shot(host, "\(name)-both-parakeet")
        controller.mode = .hold
        await shot(host, "\(name)-hold")
        controller.micUID = "нет-такого-микрофона"
        controller.setHotKey(keyCode: 96, modifiers: 0)
        await shot(host, "\(name)-mic-key")
        controller.addExcluded("com.apple.finder")
        controller.addExcluded("no.such.app.id")
        await shot(host, "\(name)-excluded")
        controller.removeExcluded("com.apple.finder")
        await shot(host, "\(name)-removed")
    }
    base()
    let host = Stand.show(VoiceView(), .dusk)
    store.selected = .parakeet
    await shot(host, "selected-before-delete")
    store.delete(.parakeet)
    await shot(host, "deleted-selected")
    store.delete(.gigaam)
    await shot(host, "deleted-all")
    try? log.write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8)
}

#if !VOICE_WIRE_BASE

// MARK: - Подставная модель

@MainActor final class FakeVoice: VoiceScreenModel {
    @Published var hotKeyLabel = "⌃⌥Space"
    @Published var hotKeyError: String?
    @Published var mode = VoiceController.Mode.toggle
    @Published var micUID: String?
    @Published var excludedApps: [String] = []
    @Published var axTrusted = true
    @Published var selected = VoiceModel.gigaam
    @Published var statuses: [VoiceModel: VoiceModelStore.Status] = [:]
    var refreshes = 0
    var statusChanges: Published<[VoiceModel: VoiceModelStore.Status]>.Publisher { $statuses }

    func addExcluded(_ bundleID: String) {}
    func removeExcluded(_ bundleID: String) {}
    func refreshPermissions() { refreshes += 1 }
    func requestAccessibility() {}
    func setHotKey(keyCode: UInt32, modifiers: UInt32) {}
    func resetHotKey() {}
    func suspendHotKey() {}
    func resumeHotKey() {}
    func status(_ model: VoiceModel) -> VoiceModelStore.Status { statuses[model] ?? .notInstalled }
    func download(_ model: VoiceModel) {}
    func cancel(_ model: VoiceModel) {}
    func delete(_ model: VoiceModel) {}
    var test: VoiceTestState? { nil }
    func beginTest() {}
    func endTest() {}
}

// MARK: - Связь

func sorted(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    guard let once = try? sorted(value), let back = try? JSONDecoder().decode(T.self, from: once),
          let twice = try? sorted(back) else { return false }
    return back == value && once == twice
}

/// Новый случай в `VoiceAction` не соберётся, пока его нет здесь и в списке ниже.
func caseName(_ action: VoiceAction) -> String {
    switch action {
    case .setMode: return "setMode"
    case .setMic: return "setMic"
    case .addExcluded: return "addExcluded"
    case .removeExcluded: return "removeExcluded"
    case .setHotKey: return "setHotKey"
    case .resetHotKey: return "resetHotKey"
    case .suspendHotKey: return "suspendHotKey"
    case .resumeHotKey: return "resumeHotKey"
    case .refreshPermissions: return "refreshPermissions"
    case .requestAccessibility: return "requestAccessibility"
    case .download: return "download"
    case .cancelDownload: return "cancelDownload"
    case .deleteModel: return "deleteModel"
    case .selectModel: return "selectModel"
    case .beginTest: return "beginTest"
    case .endTest: return "endTest"
    }
}

@MainActor func wire() {
    let actions: [VoiceAction] = [
        .setMode(.hold), .setMic("uid"), .setMic(nil), .addExcluded("com.example.a"), .removeExcluded("com.example.a"),
        .setHotKey(keyCode: 49, modifiers: 4096), .resetHotKey, .suspendHotKey, .resumeHotKey, .refreshPermissions,
        .requestAccessibility, .download(.gigaam), .cancelDownload(.parakeet), .deleteModel(.gigaam), .selectModel(.parakeet),
        .beginTest, .endTest,
    ]
    check(Set(actions.map(caseName)).count == 16, "в списке все 16 действий")
    check(actions.allSatisfy(roundTrips), "действия: JSON туда и обратно, байты с sortedKeys те же")

    let statuses: [VoiceModelStore.Status] = [.notInstalled, .downloading(progress: 0.25), .verifying, .installed, .failed("ошибка")]
    let state = VoiceState(hotKeyLabel: "⌃⌥Space", hotKeyError: "занято", mode: .hold, micUID: "uid", excludedApps: ["com.example.a"],
                           axTrusted: false, models: statuses.map { VoiceModelRow(model: .gigaam, status: $0) }, selected: .parakeet,
                           test: VoiceTestState(phrase: "текст", serial: 3), recording: true)
    check(roundTrips(state), "состояние со всеми полями и статусами: JSON туда и обратно")
    var bare = state
    bare.hotKeyError = nil
    bare.micUID = nil
    bare.test = nil
    check(roundTrips(bare), "состояние без необязательных полей: JSON туда и обратно")
    if let json = try? sorted(bare), let text = String(data: json, encoding: .utf8) {
        check(!text.contains("phrase") && !text.contains("test"), "режим выключен: ключей проверки в JSON нет")
    }

    let garbage = [
        ("неизвестное действие", #"{"explode":{}}"#),
        ("неизвестная модель", #"{"selectModel":{"_0":"evil"}}"#),
        ("неизвестный режим", #"{"setMode":{"_0":"evil"}}"#),
        ("клавиша за пределом UInt32", #"{"setHotKey":{"keyCode":5000000000,"modifiers":0}}"#),
        ("отрицательные модификаторы", #"{"setHotKey":{"keyCode":49,"modifiers":-1}}"#),
        ("строка вместо списка", #"{"addExcluded":{"_0":1}}"#),
    ]
    for (name, text) in garbage {
        check((try? JSONDecoder().decode(VoiceAction.self, from: Data(text.utf8))) == nil, "разбор отверг: \(name)")
    }

    check(VoiceController.wireStatus(.downloading(progress: 0.1234)) == .downloading(progress: 0.12), "прогресс идёт целыми процентами")
    if case let .failed(text) = VoiceController.wireStatus(.failed(String(repeating: "я", count: 5000))) {
        check(text.count == 300, "длинный текст ошибки обрезан")
    } else {
        check(false, "статус ошибки остался ошибкой")
    }
}

// MARK: - Отказы

@MainActor func refused(_ action: VoiceAction, _ name: String) {
    let controller = VoiceController.shared
    let before = controller.wireState
    let error = controller.handle(action)
    check(error != nil && controller.wireState == before, "отказ: \(name)\(error.map { " («\($0)»)" } ?? " НЕ ОТВЕРГНУТО")")
}

@MainActor func accepted(_ action: VoiceAction, _ name: String, _ condition: () -> Bool) {
    check(VoiceController.shared.handle(action) == nil && condition(), "принято: \(name)")
}

@MainActor func validations() async {
    let controller = VoiceController.shared
    let store = VoiceModelStore.shared

    // Клавиши
    let defaultLabel = controller.hotKeyLabel
    refused(.setHotKey(keyCode: 49, modifiers: 0), "пробел без модификатора")
    refused(.setHotKey(keyCode: 49, modifiers: UInt32(1 << 9)), "только shift")
    refused(.setHotKey(keyCode: 9999, modifiers: 4096), "неизвестная клавиша")
    refused(.setHotKey(keyCode: 49, modifiers: 4096 | 0x8000_0000), "чужие биты модификаторов")
    accepted(.setHotKey(keyCode: 96, modifiers: 0), "F5 без модификатора") { controller.hotKeyLabel == "F5" }
    accepted(.resetHotKey, "сброс клавиши") { controller.hotKeyLabel == defaultLabel }
    accepted(.suspendHotKey, "приостановить клавишу") { true }
    accepted(.resumeHotKey, "вернуть клавишу") { true }

    // Режим и разрешения
    accepted(.setMode(.hold), "режим «пока держу»") { controller.mode == .hold }
    accepted(.setMode(.toggle), "режим «нажал»") { controller.mode == .toggle }
    accepted(.refreshPermissions, "обновить разрешения") { true }

    // Микрофон
    refused(.setMic("нет-такого-микрофона"), "неизвестный микрофон")
    refused(.setMic(String(repeating: "x", count: 100_000)), "огромная строка вместо микрофона")
    if let device = VoiceRecorder.inputDevices().first {
        accepted(.setMic(device.uid), "настоящий микрофон") { controller.micUID == device.uid }
    } else {
        print("—    на этом Mac нет входов: выбор настоящего микрофона не проверен")
    }
    accepted(.setMic(nil), "системный микрофон") { controller.micUID == nil }
    controller.micUID = "выбран-и-отключён"
    accepted(.setMic("выбран-и-отключён"), "выбранный отключённый микрофон выбирается заново") { controller.micUID == "выбран-и-отключён" }
    controller.micUID = nil

    // Исключения
    refused(.addExcluded(""), "пустой идентификатор")
    refused(.addExcluded(String(repeating: "a", count: 256)), "идентификатор длиннее 255")
    refused(.addExcluded("../../etc/passwd"), "путь вместо идентификатора")
    refused(.addExcluded("com.example.a\nb"), "перевод строки в идентификаторе")
    refused(.addExcluded("ком.пример"), "не ASCII")
    refused(.addExcluded(Kit.hubBundleID), "сам лаунчер")
    refused(.removeExcluded("com.example.absent"), "убрать то, чего нет в списке")
    accepted(.addExcluded("com.example.app_1-x"), "обычный идентификатор") { controller.excludedApps == ["com.example.app_1-x"] }
    accepted(.addExcluded("com.example.app_1-x"), "повтор ничего не добавляет") { controller.excludedApps == ["com.example.app_1-x"] }
    accepted(.removeExcluded("com.example.app_1-x"), "убрать из списка") { controller.excludedApps.isEmpty }
    for index in 0..<200 { controller.addExcluded("com.example.fill\(index)") }
    refused(.addExcluded("com.example.overflow"), "список из 200 полон")
    for id in controller.excludedApps { controller.removeExcluded(id) }

    // Модели: подставные файлы, настоящей загрузки нет — отмена идёт раньше, чем задача успевает начаться.
    refused(.download(.gigaam), "скачать установленную")
    refused(.cancelDownload(.gigaam), "отменить загрузку, которой нет")
    accepted(.selectModel(.parakeet), "выбрать установленную") { store.selected == .parakeet }
    accepted(.selectModel(.gigaam), "выбрать обратно") { store.selected == .gigaam }
    accepted(.deleteModel(.parakeet), "удалить установленную") {
        store.status(.parakeet) == .notInstalled && !VoiceModelStore.isInstalled(.parakeet)
    }
    refused(.deleteModel(.parakeet), "удалить неустановленную")
    refused(.selectModel(.parakeet), "выбрать неустановленную")
    accepted(.download(.parakeet), "скачать неустановленную") {
        if case .downloading = store.status(.parakeet) { return true }
        return false
    }
    refused(.download(.parakeet), "скачать то, что уже качается")
    refused(.deleteModel(.parakeet), "удалить то, что качается")
    refused(.selectModel(.parakeet), "выбрать то, что качается")
    accepted(.cancelDownload(.parakeet), "отменить загрузку") { true }
    var waited = 0
    while store.status(.parakeet) != .notInstalled, waited < 50 {
        await pause(0.1)
        waited += 1
    }
    check(store.status(.parakeet) == .notInstalled, "после отмены модель не установлена")
    check(VoiceModelStore.shared.statuses.keys.count == VoiceModel.allCases.count, "статусы есть у всех моделей")
}

// MARK: - Режим проверки

@MainActor func testMode() {
    let controller = VoiceController.shared
    func json() -> String { (try? sorted(controller.wireState)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    check(controller.wireState.test == nil, "сначала режим выключен")
    check(!controller.captureTestText("секрет-раз"), "режим выключен: текст не забран, пойдёт обычной вставкой")
    check(controller.wireState.test == nil && !json().contains("секрет-раз"), "режим выключен: текста нет ни в состоянии, ни в JSON")

    check(controller.handle(.beginTest) == nil, "режим включается действием")
    check(controller.wireState.test == VoiceTestState(phrase: nil, serial: 0), "включён, текста ещё нет")
    check(controller.captureTestText("секрет-два"), "режим включён: текст забран")
    check(controller.wireState.test == VoiceTestState(phrase: "секрет-два", serial: 1) && json().contains("секрет-два"), "текст в состоянии и в JSON")
    check(controller.captureTestText("секрет-два") && controller.wireState.test?.serial == 2, "та же фраза ещё раз отличима по номеру")
    check(controller.captureTestText(String(repeating: "я", count: 5000)) && controller.wireState.test?.phrase?.count == VoiceTestState.maxPhrase, "длинная фраза обрезана")
    check(controller.captureTestText("секрет-три") && controller.handle(.endTest) == nil, "режим выключается действием")
    check(controller.wireState.test == nil && !json().contains("секрет-три") && controller.test == nil, "выключен: текст забыт и в состоянии его нет")
    check(!controller.captureTestText("секрет-четыре") && !json().contains("секрет-четыре"), "после выключения текст снова не забирается")

    controller.beginTest(now: Date() - VoiceTestState.lifetime - 1)
    check(controller.wireState.test == nil, "срок вышел: в состоянии режима нет")
    check(!controller.captureTestText("секрет-пять") && controller.test == nil && !json().contains("секрет-пять"), "срок вышел: текст не забран, режим снят")

    _ = controller.handle(.beginTest)
    _ = controller.captureTestText("секрет-шесть")
    controller.stop()
    check(controller.wireState.test == nil && controller.test == nil, "остановка модуля снимает режим и забывает текст")
}

// MARK: - Экран с подставной моделью

@MainActor func screen() async {
    let controller = VoiceController.shared
    let store = VoiceModelStore.shared
    store.selected = .gigaam
    controller.mode = .toggle
    controller.micUID = nil

    let fake = FakeVoice()
    fake.axTrusted = controller.axTrusted
    fake.hotKeyLabel = controller.hotKeyLabel
    fake.statuses = [.gigaam: .installed, .parakeet: .installed]
    for (name, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        let local = Stand.show(VoiceView(), theme)
        await pause()
        let localShot = Stand.snapshot(local)
        let host = Stand.show(VoiceView(voice: fake), theme)
        await pause()
        let diff = differingPixels(Stand.snapshot(host), localShot)
        check(diff == 0, "\(name): подставная модель рисует то же, что встроенная, разных пикселей \(diff)")
    }
    let host = Stand.show(VoiceView(voice: fake), .dusk)
    await pause()
    let plain = Stand.snapshot(host)
    check(fake.refreshes > 0, "экран при открытии обновляет разрешения через модель")

    func differs(_ name: String, _ change: () -> Void) async {
        change()
        await pause()
        check(differingPixels(Stand.snapshot(host), plain) > 0, "экран рисует: \(name)")
        fake.statuses = [.gigaam: .installed, .parakeet: .installed]
        fake.selected = .gigaam
        fake.hotKeyError = nil
        fake.axTrusted = controller.axTrusted
        fake.hotKeyLabel = controller.hotKeyLabel
        fake.mode = .toggle
        fake.excludedApps = []
    }
    await differs("загрузку") { fake.statuses[.parakeet] = .downloading(progress: 0.42) }
    await differs("проверку файла") { fake.statuses[.parakeet] = .verifying }
    await differs("ошибку загрузки") { fake.statuses[.parakeet] = .failed("Сервер ответил 500") }
    await differs("неустановленную модель") { fake.statuses[.parakeet] = .notInstalled }
    await differs("занятую клавишу") { fake.hotKeyError = "Это сочетание занято, выбери другое" }
    await differs("другую клавишу") { fake.hotKeyLabel = "F5" }
    await differs("режим") { fake.mode = .hold }
    await differs("исключения") { fake.excludedApps = ["com.apple.finder"] }
    await differs("подсказку об универсальном доступе") { fake.axTrusted = !controller.axTrusted }

    // @Published шлёт значение до записи: экран читает прежние статусы и видит пропажу со следующего сигнала. Как во встроенном.
    fake.statuses[.gigaam] = .notInstalled
    await pause()
    fake.statuses[.gigaam] = .notInstalled
    await pause()
    check(fake.selected == .parakeet, "выбранная модель пропала, а другая есть: экран переключает через модель")
}

/// Тот же экран на состоянии, прошедшем через связь (кодирование, разбор, `RemoteVoiceModel`), что и на встроенной модели.
@MainActor func remoteScreen() async {
    let controller = VoiceController.shared
    controller.mode = .toggle
    controller.micUID = nil
    for excluded in controller.excludedApps { controller.removeExcluded(excluded) }
    controller.resetHotKey()
    let link = RemoteModuleLink(
        state: { LinkWire.encoded(VoiceController.shared.wireState) },
        action: { _ in Data() }, setWatch: { _ in }, onPing: { _ in })
    let remote = RemoteVoiceModel(id: "test.voice-wire", link: link, canRead: { true })
    func variant(_ name: String, _ change: () -> Void) async {
        change()
        await remote.read()
        check(remote.state == controller.wireState, "\(name): состояние из связи равно состоянию контроллера")
        for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
            let local = Stand.show(VoiceView(), theme)
            await pause()
            let localShot = Stand.snapshot(local)
            let host = Stand.show(VoiceView(voice: remote), theme)
            await pause()
            let diff = differingPixels(Stand.snapshot(host), localShot)
            check(diff == 0, "\(name) \(themeName): экран на состоянии из связи совпал со встроенным, разных пикселей \(diff)")
        }
    }
    await variant("по умолчанию") {}
    await variant("режим «пока держу»") { controller.mode = .hold }
    await variant("другая клавиша") { controller.setHotKey(keyCode: 96, modifiers: 256) }
    await variant("исключения") { controller.addExcluded("com.apple.finder") }
    controller.mode = .toggle
    controller.resetHotKey()
    controller.removeExcluded("com.apple.finder")
}

@MainActor func run() async {
    wire()
    await screen()
    await remoteScreen()
    await validations()
    testMode()
    finish()
}

#endif

@main
enum Main {
    static func main() {
        prepareModels()
        cleanSettings()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            switch CommandLine.arguments[1] {
            case "shots":
                await shots(CommandLine.arguments[2])
                cleanSettings()
                exit(0)
            #if !VOICE_WIRE_BASE
            case "run":
                await run()
            case "compare":
                compare(CommandLine.arguments[2], CommandLine.arguments[3])
            #endif
            default:
                refuse("неизвестная роль")
            }
        }
        app.run()
    }
}

#if !VOICE_WIRE_BASE
/// Снимки встроенного экрана из старых и новых исходников.
func compare(_ before: String, _ after: String) -> Never {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: before)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    check(names.count == 15, "снимков \(names.count)")
    for name in names {
        guard let a = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(before)/\(name)"))) ?? Data()),
              let b = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(after)/\(name)"))) ?? Data()) else {
            check(false, "\(name): снимок не читается")
            continue
        }
        let diff = differingPixels(a, b)
        check(diff == 0, "до и после \(name): разных пикселей \(diff) из \(a.pixelsWide * a.pixelsHigh)")
    }
    let first = names.first.flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(before)/\($0)"))) ?? Data()) }
    let last = names.last.flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(before)/\($0)"))) ?? Data()) }
    if let first, let last {
        check(differingPixels(first, last) > 0, "снимки разные, не пустые")
    }
    finish()
}
#endif
