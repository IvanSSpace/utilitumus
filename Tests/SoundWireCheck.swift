import AppKit
import Combine
import SwiftUI

// Связь и экран модуля «Звук» без утилиты. Запуск: Tests/run-sound-wire-check.sh
// Монитор не запускается и устройства не меняются: `enforcePolicy` здесь счётчик, окно за экраном и прозрачное.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let micBuiltIn = DisplayDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn, isConnected: true)
let micUSB = DisplayDevice(uid: "usb-mic", name: "fifine Microphone", transport: .usb, isConnected: true)
let micOld = DisplayDevice(uid: "old-mic", name: "Старый USB", transport: .usb, isConnected: false)
let micBluetooth = DisplayDevice(uid: "airpods-in", name: "AirPods Pro", transport: .bluetooth, isConnected: true)
let micVirtual = DisplayDevice(uid: "loopback-in", name: "Loopback Audio", transport: .virtual, isConnected: true)
let outBuiltIn = DisplayDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn, isConnected: true)
let outDisplay = DisplayDevice(uid: "lg-display", name: "LG UltraFine", transport: .display, isConnected: true)
let outOld = DisplayDevice(uid: "old-dac", name: "USB DAC", transport: .usb, isConnected: false)
let outBluetooth = DisplayDevice(uid: "airpods-out", name: "AirPods Pro", transport: .bluetooth, isConnected: true)
let outVirtual = DisplayDevice(uid: "zoom-out", name: "ZoomAudioDevice", transport: .virtual, isConnected: true)

let allInputs = [micBuiltIn, micUSB, micOld, micBluetooth, micVirtual]
let allOutputs = [outBuiltIn, outDisplay, outOld, outBluetooth, outVirtual]

func fixture(primary: String? = nil, output: OutputChoice = .builtIn, locked: Bool = true,
             inputBluetooth: Bool = false) -> SoundState {
    SoundState(currentInputName: inputBluetooth ? "AirPods Pro" : "MacBook Pro Microphone",
               currentInputIsBluetooth: inputBluetooth, currentOutputName: "MacBook Pro Speakers",
               displayInputs: allInputs, displayOutputs: allOutputs, primaryInputUID: primary,
               outputChoice: output, isBluetoothLocked: locked)
}

/// Настоящие объекты модуля в этом состоянии. Через сами объекты, не через `handle`: он сам проверяется.
@MainActor func pin(_ state: SoundState) {
    let monitor = MonitorState.shared
    monitor.currentInputName = state.currentInputName
    monitor.currentInputIsBluetooth = state.currentInputIsBluetooth
    monitor.currentOutputName = state.currentOutputName
    monitor.displayInputs = state.displayInputs
    monitor.displayOutputs = state.displayOutputs
    PrimaryInputStore.shared.select(state.primaryInputUID)
    PrimaryOutputStore.shared.select(state.outputChoice)
    LockState.shared.isLocked = state.isBluetoothLocked
}

@MainActor final class FakeSoundModel: SoundModel {
    @Published var state: SoundState
    var calls: [SoundAction] = []
    init(_ state: SoundState) { self.state = state }

    var currentInputName: String { state.currentInputName }
    var currentInputIsBluetooth: Bool { state.currentInputIsBluetooth }
    var currentOutputName: String { state.currentOutputName }
    var displayInputs: [DisplayDevice] { state.displayInputs }
    var displayOutputs: [DisplayDevice] { state.displayOutputs }
    var primaryInputUID: String? { state.primaryInputUID }
    var outputChoice: OutputChoice { state.outputChoice }
    var isBluetoothLocked: Bool {
        get { state.isBluetoothLocked }
        set { calls.append(.setBluetoothLocked(newValue)) }
    }
    func selectInput(uid: String) { calls.append(.selectInput(uid)) }
    func selectOutput(uid: String) { calls.append(.selectOutput(uid)) }
    func selectSystemOutput() { calls.append(.selectSystemOutput) }
}

// MARK: - Кодирование

func encoded(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(value)
}

/// Как будущий общий разбор: разбирается и совпадает со своим каноническим видом.
func acceptedAction(_ text: String) -> SoundAction? {
    let data = Data(text.utf8)
    guard let action = try? JSONDecoder().decode(SoundAction.self, from: data), encoded(action) == data else { return nil }
    return action
}

func wirePure() {
    let states = [
        fixture(),
        fixture(primary: "usb-mic", output: .device("lg-display"), locked: false, inputBluetooth: true),
        fixture(primary: "old-mic", output: .system),
    ]
    for state in states {
        let bytes = encoded(state)
        let back = try? JSONDecoder().decode(SoundState.self, from: bytes)
        check(back == state && back.map(encoded) == bytes, "состояние переживает JSON, байты те же: \(state.outputChoice)")
    }
    let actions: [(SoundAction, String)] = [
        (.selectInput("usb-mic"), #"{"selectInput":{"_0":"usb-mic"}}"#),
        (.selectOutput("lg-display"), #"{"selectOutput":{"_0":"lg-display"}}"#),
        (.selectSystemOutput, #"{"selectSystemOutput":{}}"#),
        (.setBluetoothLocked(false), #"{"setBluetoothLocked":{"_0":false}}"#),
    ]
    for (action, text) in actions {
        check(String(decoding: encoded(action), as: UTF8.self) == text, "\(action) кодируется как \(text)")
        check(acceptedAction(text) == action, "\(text) разбирается обратно")
    }
    let foreign = [
        #"{"explode":{}}"#, "{}", #"[{"selectSystemOutput":{}}]"#, "{не json", "",
        #"{"selectInput":{}}"#, #"{"selectInput":{"_0":1}}"#, #"{"setBluetoothLocked":{"_0":1}}"#,
        #"{"selectSystemOutput":{},"setBluetoothLocked":{"_0":true}}"#,
        #"{"selectSystemOutput":{},"x":1}"#, #"{"selectSystemOutput":{"x":1}}"#,
        #"{"selectInput":{"_0":"usb-mic","x":1}}"#,
        #"{"selectInput":{"_0":"a"},"selectInput":{"_0":"b"}}"#,
    ]
    for text in foreign { check(acceptedAction(text) == nil, "отвергнуто: \(text)") }

    let text = String(decoding: encoded(fixture()), as: UTF8.self)
    let future = text.replacingOccurrences(of: #"{"currentInputIsBluetooth""#, with: #"{"future":1,"currentInputIsBluetooth""#)
    check(future != text && (try? JSONDecoder().decode(SoundState.self, from: Data(future.utf8))) == fixture(), "новое поле от утилиты не ломает чтение")
    let warp = text.replacingOccurrences(of: #""transport":"usb""#, with: #""transport":"warp""#)
    check(warp != text && (try? JSONDecoder().decode(SoundState.self, from: Data(warp.utf8))) == nil, "неизвестный транспорт состояние не проходит: см. отчёт")
}

// MARK: - Проверки действий

@MainActor func validations() {
    var enforced = 0
    let controller = SoundController(enforcePolicy: { enforced += 1 })
    var published = 0
    let watch = controller.objectWillChange.sink { published += 1 }
    defer { watch.cancel() }
    let long = String(repeating: "x", count: 100_000)

    func refused(_ start: SoundState, _ action: SoundAction, _ name: String) {
        pin(start)
        enforced = 0
        let before = controller.wireState
        let error = controller.handle(action)
        check(error != nil, "\(name): отказ «\(error ?? "нет")»")
        check(controller.wireState == before, "\(name): состояние то же")
        check(enforced == 0, "\(name): политика не запускалась")
    }
    func accepted(_ start: SoundState, _ action: SoundAction, _ name: String, _ expected: (inout SoundState) -> Void) {
        pin(start)
        enforced = 0
        published = 0
        var want = start
        expected(&want)
        let error = controller.handle(action)
        check(error == nil, "\(name): принято\(error.map { " — \($0)" } ?? "")")
        check(controller.wireState == want, "\(name): состояние как ждали")
        check(enforced == 1, "\(name): политика запущена один раз, запусков \(enforced)")
        check(published > 0, "\(name): экран узнал об изменении")
    }

    let open = fixture(locked: false)
    refused(open, .selectInput("nope"), "вход: чужой uid")
    refused(open, .selectInput(""), "вход: пустой uid")
    refused(open, .selectInput(long), "вход: очень длинный uid")
    refused(open, .selectInput("loopback-in"), "вход: виртуальное устройство из списка")
    refused(open, .selectInput("BuiltInSpeakerDevice"), "вход: uid выхода")
    refused(fixture(locked: true), .selectInput("airpods-in"), "вход: Bluetooth при блокировке")
    refused(open, .selectOutput("nope"), "выход: чужой uid")
    refused(open, .selectOutput(""), "выход: пустой uid")
    refused(open, .selectOutput(long), "выход: очень длинный uid")
    refused(open, .selectOutput("zoom-out"), "выход: виртуальное устройство из списка")
    refused(open, .selectOutput("usb-mic"), "выход: uid входа")
    var empty = fixture()
    empty.displayInputs = []
    empty.displayOutputs = []
    refused(empty, .selectInput("usb-mic"), "вход: монитор ещё не прошёл, списка нет")
    refused(empty, .selectOutput("lg-display"), "выход: монитор ещё не прошёл, списка нет")

    accepted(open, .selectInput("usb-mic"), "вход: USB") { $0.primaryInputUID = "usb-mic" }
    accepted(open, .selectInput("old-mic"), "вход: не подключён, как на экране") { $0.primaryInputUID = "old-mic" }
    accepted(open, .selectInput("airpods-in"), "вход: Bluetooth без блокировки") { $0.primaryInputUID = "airpods-in" }
    accepted(fixture(primary: "usb-mic", locked: false), .selectInput("BuiltInMicrophoneDevice"), "вход: встроенный хранится как nil") { $0.primaryInputUID = nil }
    accepted(fixture(locked: true), .selectInput("usb-mic"), "вход: блокировка не мешает USB") { $0.primaryInputUID = "usb-mic" }
    accepted(open, .selectOutput("lg-display"), "выход: монитор") { $0.outputChoice = .device("lg-display") }
    accepted(open, .selectOutput("old-dac"), "выход: не подключён, как на экране") { $0.outputChoice = .device("old-dac") }
    accepted(fixture(locked: true), .selectOutput("airpods-out"), "выход: Bluetooth блокировка не касается") { $0.outputChoice = .device("airpods-out") }
    accepted(fixture(output: .system), .selectOutput("BuiltInSpeakerDevice"), "выход: встроенный хранится как .builtIn") { $0.outputChoice = .builtIn }
    accepted(open, .selectSystemOutput, "выход: как решит macOS") { $0.outputChoice = .system }
    accepted(fixture(locked: true), .setBluetoothLocked(false), "блокировка снята") { $0.isBluetoothLocked = false }
    accepted(fixture(locked: false), .setBluetoothLocked(true), "блокировка включена") { $0.isBluetoothLocked = true }

    // Экран зовёт методы модели, у настоящего контроллера они идут в тот же `handle`.
    pin(open)
    enforced = 0
    controller.selectInput(uid: "usb-mic")
    controller.selectOutput(uid: "lg-display")
    check(controller.primaryInputUID == "usb-mic" && controller.outputChoice == .device("lg-display") && enforced == 2, "методы модели меняют выбор и запускают политику")
    controller.selectSystemOutput()
    controller.isBluetoothLocked = true
    check(controller.outputChoice == .system && controller.isBluetoothLocked && enforced == 4, "остальные методы тоже")
    controller.selectInput(uid: "airpods-in")
    check(controller.primaryInputUID == "usb-mic" && enforced == 4, "метод с запрещённым устройством ничего не меняет")
}

// MARK: - Снимки

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

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

    /// Показывает экран в окне. Вид возвращается: нажатия идут в него же.
    static func show(_ view: some View, _ theme: DSTheme, size: NSSize) async -> NSView {
        window.setContentSize(size)
        let host = NSHostingView(rootView: view
            .environment(\.dsTheme, theme)
            .environment(\.colorScheme, .dark)
            .background(Color(white: 0.12))
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        await pause(0.35)
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
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * pixelBytes, pb + y * a.bytesPerRow + x * pixelBytes, pixelBytes) != 0 {
            count += 1
        }
    }
    return count
}

@MainActor func pixels() async {
    let cases: [(String, SoundState)] = [
        ("по умолчанию", fixture()),
        ("USB и монитор, Bluetooth свободен", fixture(primary: "usb-mic", output: .device("lg-display"), locked: false, inputBluetooth: true)),
        ("отключённый вход, решает macOS", fixture(primary: "old-mic", output: .system)),
        ("Bluetooth основной при блокировке", fixture(primary: "airpods-in", output: .device("airpods-out"))),
    ]
    // Две колонки и одна: `ViewThatFits` выбирает по ширине.
    let sizes = [NSSize(width: 738, height: 660), NSSize(width: 520, height: 900)]
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        for size in sizes {
            var shots: [NSBitmapImageRep] = []
            for (name, state) in cases {
                let label = "\(themeName) \(Int(size.width)) \(name)"
                pin(state)
                let legacy = Stand.snapshot(await Stand.show(LegacySoundView(), theme, size: size))
                let real = Stand.snapshot(await Stand.show(SoundView(), theme, size: size))
                let fake = Stand.snapshot(await Stand.show(SoundView(model: FakeSoundModel(state)), theme, size: size))
                let total = legacy.pixelsWide * legacy.pixelsHigh
                check(differingPixels(legacy, real) == 0, "\(label): экран до и после, разных пикселей \(differingPixels(legacy, real)) из \(total)")
                check(differingPixels(legacy, fake) == 0, "\(label): подставная модель, разных пикселей \(differingPixels(legacy, fake))")
                shots.append(real)
            }
            for i in 1..<shots.count {
                check(differingPixels(shots[0], shots[i]) > 0, "\(themeName) \(Int(size.width)): состояния \(cases[i].0) и по умолчанию различаются, снимки не пустые")
            }
        }
    }
}

/// Живое обновление: экран настоящего контроллера перерисовывается от каждого из четырёх объектов.
@MainActor func refreshEveryObject() async {
    let size = NSSize(width: 738, height: 660)
    pin(fixture())
    let view = await Stand.show(SoundView(), DSTheme.dusk, size: size)
    func changed(_ name: String, _ change: () -> Void) async {
        let before = Stand.snapshot(view)
        change()
        await pause(0.35)
        check(differingPixels(before, Stand.snapshot(view)) > 0, "экран обновился: \(name)")
    }
    await changed("монитор") { MonitorState.shared.currentOutputName = "Другое имя" }
    await changed("блокировка") { LockState.shared.isLocked = false }
    await changed("выбранный микрофон") { PrimaryInputStore.shared.select("usb-mic") }
    await changed("выбранный выход") { PrimaryOutputStore.shared.select(.system) }
}

/// Настоящие нажатия по экрану с подставной моделью: сетка кликов по всей странице собирает всё, что экран умеет просить.
@MainActor func clicks() async {
    let size = NSSize(width: 738, height: 660)
    func sweep(_ state: SoundState) async -> [SoundAction] {
        let model = FakeSoundModel(state)
        let view = await Stand.show(SoundView(model: model), DSTheme.dusk, size: size)
        Stand.window.ignoresMouseEvents = false
        defer { Stand.window.ignoresMouseEvents = true }
        var seen: [SoundAction] = []
        // Строки выбора нажимаются по всей ширине, тумблер только у правого края левой колонки. По высоте шаг меньше строки.
        for x in [CGFloat(60), 329, 390] {
            for y in stride(from: CGFloat(20), to: size.height, by: 14) {
                let point = view.convert(NSPoint(x: x, y: y), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: Stand.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                }
                guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { continue }
                // Отпускание сначала в очередь: тумблер на нажатии сам ждёт его во вложенном цикле, и sendEvent иначе не вернётся.
                NSApp.postEvent(up, atStart: false)
                Stand.window.sendEvent(down)
                await pause(0.01)
            }
        }
        await pause(0.2)
        for call in model.calls where !seen.contains(call) { seen.append(call) }
        return seen
    }
    let want: [SoundAction] = [
        .selectInput("BuiltInMicrophoneDevice"), .selectInput("usb-mic"), .selectInput("old-mic"), .selectInput("airpods-in"),
        .selectOutput("BuiltInSpeakerDevice"), .selectOutput("lg-display"), .selectOutput("old-dac"), .selectOutput("airpods-out"),
        .selectSystemOutput,
    ]
    let free = await sweep(fixture(locked: false))
    for action in want { check(free.contains(action), "нажатие: \(action)") }
    check(free.contains(.setBluetoothLocked(true)), "нажатие: тумблер просит включить блокировку")
    let foreign = free.filter { !want.contains($0) && $0 != .setBluetoothLocked(true) }
    check(foreign.isEmpty, "нажатия не просят лишнего: \(foreign)")
    let locked = await sweep(fixture(locked: true))
    check(!locked.contains(.selectInput("airpods-in")) && locked.contains(.selectInput("usb-mic")), "заблокированный Bluetooth-микрофон не нажимается, остальные нажимаются")
    check(locked.contains(.setBluetoothLocked(false)), "нажатие: тумблер просит снять блокировку")
}

// MARK: - Жизненный цикл модуля утилиты

func reply(_ data: Data) -> LinkReply<SoundState>? { try? JSONDecoder().decode(LinkReply<SoundState>.self, from: data) }

/// Настоящий `SoundModule` с настоящим монитором: он слушает устройства и читает их, но в этой сборке ничего не пишет.
@MainActor func lifecycle() async {
    let module = SoundModule()
    let monitor = AudioMonitor.shared
    let lock = encoded(SoundAction.setBluetoothLocked(false))
    LockState.shared.isLocked = true
    check(!monitor.isActive, "init модуля монитор не запускает")

    var answer = reply(module.handle(lock))
    check(answer?.error != nil && LockState.shared.isLocked, "до start действие отвергнуто, настройка прежняя")

    module.start()
    check(monitor.isActive, "start: монитор работает")
    answer = reply(module.handle(lock))
    check(answer?.error == nil && answer?.state.isBluetoothLocked == false && !LockState.shared.isLocked, "работает: действие применено, ответ с новым состоянием")
    for (name, payload) in [("мусор", "{не json"), ("чужой ключ", #"{"selectSystemOutput":{},"x":1}"#), ("два действия", #"{"selectSystemOutput":{},"setBluetoothLocked":{"_0":true}}"#),
                            ("длинный uid", #"{"selectInput":{"_0":""#  + String(repeating: "a", count: 2000) + #""}}"#)] {
        let bad = reply(module.handle(Data(payload.utf8)))
        check(bad?.error != nil && bad?.state == module.state().decoded(), "\(name): отказ, состояние прежнее")
    }
    answer = reply(module.handle(encoded(SoundAction.selectInput("нет-такого"))))
    check(answer?.error != nil, "неизвестный микрофон отвергнут: \(answer?.error ?? "нет")")
    check(module.statusLine(passiveReason: nil) == (MonitorState.shared.currentInputName == "—" ? "слежу за микрофоном" : MonitorState.shared.currentInputName), "строка статуса как у карточки встроенного")

    module.enterPassive()
    check(!monitor.isActive, "пассивная: монитор остановлен, устройство никто не возвращает")
    check(module.statusLine(passiveReason: "Ждём передачу от центра") == "Ждём передачу от центра", "пассивная: строка с причиной")
    LockState.shared.isLocked = true
    answer = reply(module.handle(lock))
    check(answer?.error != nil && LockState.shared.isLocked, "пассивная: действие отвергнуто")

    // Пока модуль стоял, центр поменял настройки: после start их видно. Исходные значения другие, иначе проверка пуста.
    PrimaryOutputStore.shared.select(.builtIn)
    PrimaryInputStore.shared.select(nil)
    LockState.shared.isLocked = true
    Kit.defaults.set("system", forKey: "UtilitumusPrimaryOutput")
    Kit.defaults.set(false, forKey: "MicGuardBluetoothLocked")
    Kit.defaults.set("usb-mic", forKey: "UtilitumusPrimaryInput")
    module.start()
    check(monitor.isActive, "после пассивной start снова запускает монитор")
    check(PrimaryOutputStore.shared.choice == .system && !LockState.shared.isLocked && PrimaryInputStore.shared.primaryUID == "usb-mic",
          "start перечитал настройки, изменённые снаружи")

    module.stopForUpdate()
    check(!monitor.isActive, "stopForUpdate: монитор остановлен")
    check(Kit.defaults.string(forKey: "UtilitumusPrimaryOutput") == "system", "stopForUpdate: выбор пользователя остался")
    module.start()
    module.stopForUninstall()
    check(!monitor.isActive, "stopForUninstall: монитор остановлен")
    module.stop()
    module.stop()
    check(!monitor.isActive, "повторный stop безвреден")
}

extension Data {
    func decoded() -> SoundState? { try? JSONDecoder().decode(SoundState.self, from: self) }
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        // У процесса нет bundle id: `.standard` здесь — домен по имени файла, настоящие настройки недостижимы.
        precondition(Bundle.main.bundleIdentifier == nil, "Стенд не должен жить под чужим bundle id")
        // Вывод построчно, и зависший стенд не держит место в очереди сборок.
        setvbuf(stdout, nil, _IOLBF, 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            print("FAIL стенд завис: 300 с")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            wirePure()
            validations()
            await pixels()
            await refreshEveryObject()
            await clicks()
            await lifecycle()
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
