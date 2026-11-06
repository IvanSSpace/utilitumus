import AppKit
import SwiftUI
import Carbon.HIToolbox

// Модель, связь и экран модуля «Буфер». Запуск: Tests/run-clipboard-wire-check.sh
// Все записи выдуманные, модель поддельная. Настоящие контроллер, хранилище, ключ и буфер обмена сюда не попадают.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
}()

func item(_ kind: ClipKind, text: String? = nil, paths: [String]? = nil, width: Int? = nil, height: Int? = nil,
          source: String? = nil, space: UUID? = nil, ago: TimeInterval = 310) -> ClipItem {
    ClipItem(id: UUID(), hash: "HASH-VALUE", kind: kind, text: text, filePaths: paths,
             imageFile: kind == .image ? "img-FILE-NAME.bin" : nil, imageWidth: width, imageHeight: height,
             sourceBundleID: source, sourceName: "SOURCE-NAME", date: Date().addingTimeInterval(-ago), spaceID: space)
}

/// Что показывает экран: одно и то же уходит в старый экран и в новый.
struct Fixture {
    var items: [ClipItem] = []
    var spaces: [ClipSpace] = []
    var excluded: [String] = []
    var hotKeyError: String?
    var storeError: String?
    var storeNotice: String?
    var limit = 500
    var ax = true
}

// MARK: - Поддельные модели

@MainActor
final class FakeClipboardModel: ClipboardModel {
    @Published var items: [ClipItem]
    @Published var spaces: [ClipSpace]
    @Published var excludedApps: [String]
    @Published var hotKeyError: String?
    @Published var storeError: String?
    @Published var storeNotice: String?
    @Published var limit: Int
    @Published var axTrusted: Bool
    @Published var keyCode = UInt32(kVK_ANSI_V)
    @Published var modifiers = UInt32(cmdKey | shiftKey)
    /// Хранилище не открыто: как у контроллера, `addSpace` молчит.
    var storeOpen = true
    /// Как свой bundle id у контроллера: `addExcluded` молчит.
    let refusedBundleID = "own.bundle.id"
    var calls: [String] = []

    init(_ scene: Fixture = Fixture()) {
        items = scene.items
        spaces = scene.spaces
        excludedApps = scene.excluded
        hotKeyError = scene.hotKeyError
        storeError = scene.storeError
        storeNotice = scene.storeNotice
        limit = scene.limit
        axTrusted = scene.ax
    }

    var wireState: ClipboardState {
        ClipboardState(model: self, recent: ClipRecentRow.wireRows(from: items, hiding: excludedApps))
    }

    var totalCount: Int { items.count }
    var historyCount: Int { items.filter { $0.spaceID == nil }.count }
    func count(inSpace id: UUID) -> Int { items.filter { $0.spaceID == id }.count }
    /// Встроенный экран видит строки целиком; вкладка центра увидит те, что пришли в состоянии.
    var showsWireRows = false
    var recent: [ClipRecentRow] { showsWireRows ? wireState.recent : ClipRecentRow.rows(from: items) }
    var hotKeyLabel: String { VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers) }

    func togglePanel() { calls.append("togglePanel") }
    func refreshPermissions() { calls.append("refreshPermissions") }
    func requestAccessibility() { calls.append("requestAccessibility") }
    func clearHistory() { calls.append("clearHistory"); items.removeAll { $0.spaceID == nil } }
    func setLimit(_ value: Int) { calls.append("setLimit"); limit = value }
    func addSpace(name: String, colorID: String) {
        calls.append("addSpace")
        if storeOpen { spaces.append(ClipSpace(id: UUID(), name: name, colorID: colorID)) }
    }
    func renameSpace(_ id: UUID, to name: String) {
        calls.append("renameSpace")
        spaces = spaces.map { $0.id == id ? ClipSpace(id: id, name: name, colorID: $0.colorID) : $0 }
    }
    func setColor(_ id: UUID, _ colorID: String) {
        calls.append("setColor")
        spaces = spaces.map { $0.id == id ? ClipSpace(id: id, name: $0.name, colorID: colorID) : $0 }
    }
    func moveSpace(_ id: UUID, by offset: Int) {
        calls.append("moveSpace")
        // Без падения на переполнении: поломка проверки в handle должна дать FAIL, а не обрыв.
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let (to, overflow) = from.addingReportingOverflow(offset)
        guard !overflow, spaces.indices.contains(to) else { return }
        spaces.insert(spaces.remove(at: from), at: to)
    }
    func deleteSpace(_ id: UUID) { calls.append("deleteSpace"); spaces.removeAll { $0.id == id } }
    func addExcluded(_ bundleID: String) {
        calls.append("addExcluded")
        if bundleID != refusedBundleID { excludedApps.append(bundleID) }
    }
    func removeExcluded(_ bundleID: String) { calls.append("removeExcluded"); excludedApps.removeAll { $0 == bundleID } }
    func setHotKey(keyCode: UInt32, modifiers: UInt32) {
        calls.append("setHotKey")
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    func resetHotKey() { calls.append("resetHotKey") }
    func suspendHotKey() { calls.append("suspendHotKey") }
    func resumeHotKey() { calls.append("resumeHotKey") }
}

/// Подставляется в старый экран вместо настоящего контроллера: поля те, что он читал.
@MainActor
final class LegacyFakeController: ObservableObject, HotKeyTarget {
    static let shared = LegacyFakeController()
    @Published var items: [ClipItem] = []
    @Published var spaces: [ClipSpace] = []
    @Published var excludedApps: [String] = []
    @Published var hotKeyError: String?
    @Published var storeError: String?
    @Published var storeNotice: String?
    @Published var limit = 500
    @Published var axTrusted = true
    var hotKeyLabel: String { VoiceHotKey.label(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) }
    var historyCount: Int { items.filter { $0.spaceID == nil }.count }

    func show(_ scene: Fixture) {
        items = scene.items
        spaces = scene.spaces
        excludedApps = scene.excluded
        hotKeyError = scene.hotKeyError
        storeError = scene.storeError
        storeNotice = scene.storeNotice
        limit = scene.limit
        axTrusted = scene.ax
    }

    func togglePanel() {}
    func refreshPermissions() {}
    func requestAccessibility() {}
    func clearHistory() {}
    func setLimit(_ value: Int) {}
    func addSpace(name: String, colorID: String) {}
    func renameSpace(_ id: UUID, to name: String) {}
    func setColor(_ id: UUID, _ colorID: String) {}
    func moveSpace(_ id: UUID, by offset: Int) {}
    func deleteSpace(_ id: UUID) {}
    func addExcluded(_ bundleID: String) {}
    func removeExcluded(_ bundleID: String) {}
    func setHotKey(keyCode: UInt32, modifiers: UInt32) {}
    func resetHotKey() {}
    func suspendHotKey() {}
    func resumeHotKey() {}
}

// MARK: - Связь

let spaceA = UUID(), spaceB = UUID(), spaceC = UUID()
let threeSpaces = [ClipSpace(id: spaceA, name: "Работа", colorID: "blue"),
                   ClipSpace(id: spaceB, name: "Дом", colorID: "green"),
                   ClipSpace(id: spaceC, name: "Коды", colorID: "red")]

@MainActor func checkRoundTrip() {
    let id = UUID()
    let actions: [ClipboardAction] = [
        .togglePanel, .refreshPermissions, .requestAccessibility, .clearHistory, .setLimit(value: 250),
        .addSpace(name: "Новое", colorID: "teal"), .renameSpace(id: id, name: "Имя"), .setColor(id: id, colorID: "pink"),
        .moveSpace(id: id, by: -1), .deleteSpace(id: id), .addExcluded(bundleID: "com.example.app"),
        .removeExcluded(bundleID: "com.example.app"), .suspendHotKey, .resumeHotKey,
        .setHotKey(keyCode: 9, modifiers: UInt32(cmdKey)), .resetHotKey,
    ]
    check(actions.count == 16, "действий 16")
    for action in actions {
        let data = try! encoder.encode(action)
        let back = try? JSONDecoder().decode(ClipboardAction.self, from: data)
        check(back == action && back.flatMap { try? encoder.encode($0) } == data,
              "действие туда и обратно: \(String(decoding: data, as: UTF8.self))")
    }
    for bad in [#"{"explode":{}}"#, #"{"setLimit":{"value":"много"}}"#, #"{"setLimit":{}}"#, #"{"deleteSpace":{"id":"не-uuid"}}"#, "{}", "[]"] {
        check((try? JSONDecoder().decode(ClipboardAction.self, from: Data(bad.utf8))) == nil, "не разбирается: \(bad)")
    }
    // Чужой ключ разбор не видит; отсекает его сверка с кодированием в общем помощнике, и она здесь срабатывает.
    let foreign = Data(#"{"togglePanel":{},"x":1}"#.utf8)
    let decoded = try? JSONDecoder().decode(ClipboardAction.self, from: foreign)
    check(decoded.flatMap { try? encoder.encode($0) } != foreign, "чужой ключ не переживает сверку с кодированием")

    let state = FakeClipboardModel(fullFixture()).wireState
    let data = try! encoder.encode(state)
    let back = try? JSONDecoder().decode(ClipboardState.self, from: data)
    check(back == state && back.flatMap { try? encoder.encode($0) } == data, "состояние туда и обратно, байты те же")
}

let tail = "SECRET-TAIL"
func fullFixture() -> Fixture {
    Fixture(items: [
        item(.text, text: "первая\nстрока " + String(repeating: "я", count: 300) + tail, source: "com.apple.TextEdit"),
        item(.link, text: "https://www.example.com/path?token=LINK-SECRET", source: "com.apple.Safari", ago: 4000),
        item(.image, width: 640, height: 480, source: "test.no.such.app", ago: 90_000),
        item(.file, paths: ["/Users/test/HIDDEN-DIR/report.pdf", "/Users/test/HIDDEN-DIR/SECOND-FILE.txt"], space: spaceA, ago: 200_000),
        item(.text, text: "закреплённая запись", space: spaceB, ago: 30),
        item(.text, text: "SIXTH-ITEM", space: spaceA),
        item(.link, text: "mailto:SEVENTH-ITEM@example.com"),
    ], spaces: threeSpaces, excluded: ["com.apple.Passwords", "test.no.such.app.2"],
       hotKeyError: "Это сочетание занято, выбери другое", storeError: "Не удалось получить ключ",
       storeNotice: "Старая история отложена в файл index-unreadable-1.bin", limit: 250, ax: false)
}

@MainActor func checkState() {
    let model = FakeClipboardModel(fullFixture())
    let state = model.wireState
    let json = String(decoding: try! encoder.encode(state), as: UTF8.self)
    let top = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    check(Set(top.keys) == ["totalCount", "historyCount", "spaces", "spaceCounts", "recent", "hotKeyLabel", "hotKeyError",
                            "storeError", "storeNotice", "limit", "excludedApps", "axTrusted"],
          "в состоянии только поля экрана: \(top.keys.sorted())")
    let row = (top["recent"] as! [[String: Any]])[0]
    check(Set(row.keys) == ["title", "sourceBundleID", "date"], "в строке только название, значок и время")
    check(state.recent.count == 5, "строк пять при семи записях")
    check(state.totalCount == 7 && state.historyCount == 4, "счётчики всех записей и истории")
    check(state.spaceCounts == [spaceA.uuidString: 2, spaceB.uuidString: 1, spaceC.uuidString: 0], "счётчики пространств, включая пустое")
    check(state.recent.allSatisfy { $0.title.count <= ClipRecentRow.maxTitleLength }, "названия обрезаны")
    check(state.recent[0].title.hasPrefix("первая строка "), "перевод строки в названии заменён")
    check(state.recent[1].title == "example.com", "у ссылки только хост")
    check(state.recent[2].title == "Картинка 640×480", "у картинки только размер")
    check(state.recent[3].title == "report.pdf", "у файла только имя")
    for secret in [tail, "LINK-SECRET", "/path", "HIDDEN-DIR", "SECOND-FILE", "HASH-VALUE", "FILE-NAME", "SOURCE-NAME",
                   "SIXTH-ITEM", "SEVENTH-ITEM", "\"items\"", "filePaths", "imageFile", "\"hash\""] {
        check(!json.contains(secret), "в состоянии нет «\(secret)»")
    }

    // Записи со скрытым типом история не принимает (ClipboardCheck); в записи такой пометки нет, поэтому здесь политика.
    for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
        check(ClipboardPolicy.shouldSkip(types: ["public.utf8-plain-text", type]), "\(type): не запоминается")
    }
    // То, что всё же могло лежать в истории: запись программы, исключённой позже.
    var hiding = fullFixture()
    hiding.items.insert(item(.text, text: "EXCLUDED-SOURCE-TEXT", source: "com.apple.Passwords"), at: 0)
    let hidingModel = FakeClipboardModel(hiding)
    let hidingState = hidingModel.wireState
    let hidingJSON = String(decoding: try! encoder.encode(hidingState), as: UTF8.self)
    check(!hidingJSON.contains("EXCLUDED-SOURCE-TEXT"), "запись исключённой программы в состояние не идёт")
    check(hidingState.recent.count == 5 && hidingState.recent[0].title.hasPrefix("первая"), "её место занимает следующая, строк снова пять")
    check(hidingModel.recent[0].title == "EXCLUDED-SOURCE-TEXT", "встроенный экран показывает её, как раньше")

    let allHidden = FakeClipboardModel(Fixture(items: [item(.text, text: "x", source: "a.b")], excluded: ["a.b"]))
    check(allHidden.wireState.recent.isEmpty && allHidden.wireState.totalCount == 1, "все скрыты: строк нет, счётчик остаётся")
}

// MARK: - Проверка действий

@MainActor func refuses(_ model: FakeClipboardModel, _ action: ClipboardAction, _ name: String, reachesModel: Bool = false) {
    let before = model.wireState
    model.calls = []
    let error = model.handle(action)
    let reached = !model.calls.isEmpty
    check(error != nil && model.wireState == before && reached == reachesModel,
          "отказ: \(name) (\(error ?? "нет текста"))")
}

@MainActor func checkRefusals() {
    func fresh() -> FakeClipboardModel {
        FakeClipboardModel(Fixture(items: [item(.text, text: "x")], spaces: threeSpaces, excluded: ["com.example.listed"]))
    }
    let model = fresh()
    let longName = String(repeating: "я", count: ClipboardWireRules.maxNameBytes / 2 + 1)
    let unknown = UUID()
    for value in [0, -1, 99, 501, Int.max, Int.min] { refuses(model, .setLimit(value: value), "лимит \(value)") }
    refuses(model, .addSpace(name: "", colorID: "blue"), "пустое имя")
    refuses(model, .addSpace(name: "   ", colorID: "blue"), "имя из пробелов")
    refuses(model, .addSpace(name: longName, colorID: "blue"), "длинное имя")
    refuses(model, .addSpace(name: "a\nb", colorID: "blue"), "перевод строки в имени")
    refuses(model, .addSpace(name: "a\u{0}b", colorID: "blue"), "нулевой символ в имени")
    refuses(model, .addSpace(name: "имя", colorID: "evil"), "чужой цвет")
    refuses(model, .addSpace(name: "имя", colorID: ""), "пустой цвет")
    refuses(model, .renameSpace(id: unknown, name: "имя"), "переименовать чужой id")
    refuses(model, .renameSpace(id: spaceA, name: " "), "переименовать в пустое")
    refuses(model, .renameSpace(id: spaceA, name: longName), "переименовать в длинное")
    refuses(model, .renameSpace(id: spaceA, name: "a\rb"), "переименовать с управляющим символом")
    refuses(model, .setColor(id: unknown, colorID: "blue"), "цвет чужому id")
    refuses(model, .setColor(id: spaceA, colorID: "evil"), "чужой цвет пространству")
    refuses(model, .moveSpace(id: unknown, by: 1), "сдвинуть чужой id")
    for offset in [0, 2, -2, Int.max, Int.min] { refuses(model, .moveSpace(id: spaceB, by: offset), "сдвиг на \(offset)") }
    refuses(model, .moveSpace(id: spaceA, by: -1), "первое выше")
    refuses(model, .moveSpace(id: spaceC, by: 1), "последнее ниже")
    refuses(model, .deleteSpace(id: unknown), "удалить чужой id")
    for bad in ["", "../evil", "a b", "приложение", "a\u{0}b", "/Applications/Evil.app", String(repeating: "a", count: ClipboardWireRules.maxBundleIDBytes + 1)] {
        refuses(model, .addExcluded(bundleID: bad), "исключить «\(bad.prefix(24))»")
    }
    refuses(model, .addExcluded(bundleID: "com.example.listed"), "исключить повторно")
    refuses(model, .addExcluded(bundleID: model.refusedBundleID), "исключить себя: модель молчит", reachesModel: true)
    refuses(model, .removeExcluded(bundleID: "com.example.other"), "убрать то, чего нет")
    refuses(model, .setHotKey(keyCode: 200, modifiers: UInt32(cmdKey)), "неизвестная клавиша")
    refuses(model, .setHotKey(keyCode: 9, modifiers: 0), "буква без модификатора")
    refuses(model, .setHotKey(keyCode: 9, modifiers: UInt32(shiftKey)), "буква только с ⇧")
    refuses(model, .setHotKey(keyCode: 9, modifiers: UInt32(cmdKey) | 0x10000), "чужой бит модификатора")
    refuses(model, .setHotKey(keyCode: 9, modifiers: .max), "все биты модификатора")
    refuses(model, .setHotKey(keyCode: .max, modifiers: UInt32(cmdKey)), "клавиша за пределами")

    let closed = fresh()
    closed.storeOpen = false
    refuses(closed, .addSpace(name: "имя", colorID: "blue"), "пространство при закрытой истории: модель молчит", reachesModel: true)
    let pinnedOnly = FakeClipboardModel(Fixture(items: [item(.text, text: "x", space: spaceA)], spaces: threeSpaces))
    refuses(pinnedOnly, .clearHistory, "очистка без записей истории")
    let manySpaces = FakeClipboardModel(Fixture(spaces: (0..<ClipboardWireRules.maxSpaces).map { ClipSpace(id: UUID(), name: "\($0)", colorID: "blue") }))
    refuses(manySpaces, .addSpace(name: "ещё", colorID: "blue"), "пространств больше предела")
    let manyApps = FakeClipboardModel(Fixture(excluded: (0..<ClipboardWireRules.maxExcludedApps).map { "a.b\($0)" }))
    refuses(manyApps, .addExcluded(bundleID: "a.other"), "исключений больше предела")
}

@MainActor func checkAccepted() {
    let model = FakeClipboardModel(Fixture(items: [item(.text, text: "x")], spaces: threeSpaces, excluded: ["com.example.listed"]))
    func accepts(_ action: ClipboardAction, _ call: String, _ effect: () -> Bool = { true }) {
        model.calls = []
        let error = model.handle(action)
        check(error == nil && model.calls == [call] && effect(), "выполнено: \(call)")
    }
    accepts(.togglePanel, "togglePanel")
    accepts(.refreshPermissions, "refreshPermissions")
    accepts(.requestAccessibility, "requestAccessibility")
    accepts(.suspendHotKey, "suspendHotKey")
    accepts(.resumeHotKey, "resumeHotKey")
    accepts(.resetHotKey, "resetHotKey")
    for value in ClipboardPolicy.limits { accepts(.setLimit(value: value), "setLimit") { model.limit == value } }
    accepts(.addSpace(name: "  Новое  ", colorID: "teal"), "addSpace") { model.spaces.last?.name == "Новое" && model.spaces.last?.colorID == "teal" }
    accepts(.addSpace(name: "👨‍👩‍👧 Семья", colorID: "pink"), "addSpace") { model.spaces.last?.name == "👨‍👩‍👧 Семья" }
    accepts(.renameSpace(id: spaceA, name: " Имя "), "renameSpace") { model.spaces[0].name == "Имя" }
    accepts(.setColor(id: spaceA, colorID: "gray"), "setColor") { model.spaces[0].colorID == "gray" }
    accepts(.moveSpace(id: spaceA, by: 1), "moveSpace") { model.spaces[1].id == spaceA }
    accepts(.moveSpace(id: spaceA, by: -1), "moveSpace") { model.spaces[0].id == spaceA }
    accepts(.deleteSpace(id: spaceB), "deleteSpace") { !model.spaces.contains { $0.id == spaceB } }
    accepts(.addExcluded(bundleID: "com.example-app.My_App2"), "addExcluded") { model.excludedApps.contains("com.example-app.My_App2") }
    for id in ClipboardPolicy.defaultExcludedApps { check(ClipboardWireRules.isBundleID(id), "годится программа по умолчанию \(id)") }
    accepts(.removeExcluded(bundleID: "com.example.listed"), "removeExcluded") { !model.excludedApps.contains("com.example.listed") }
    accepts(.setHotKey(keyCode: 9, modifiers: UInt32(controlKey | optionKey)), "setHotKey") { model.keyCode == 9 }
    accepts(.setHotKey(keyCode: 122, modifiers: 0), "setHotKey") { model.keyCode == 122 }
    accepts(.clearHistory, "clearHistory") { model.historyCount == 0 }
}

// MARK: - Экран

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

    /// Тема задана прямо, а не из настроек: suite стенда общий, чужой запуск не должен менять снимок.
    static func render(_ view: some View, _ name: String, out: String) async -> NSBitmapImageRep {
        let theme = DSTheme.dusk
        let root = view
            .background(ZStack { DSBackground(module: .clipboard, neutral: false); theme.card })
            .environment(\.dsTheme, theme)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
            .frame(width: 738, height: 660)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 660)
        window.contentView = host
        try? await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/png/\(name).png"))
        window.contentView = nil
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

/// Названия, которые обрезка могла бы задеть: длинные, узкие, широкие, с переводами строк.
func longFixture() -> Fixture {
    Fixture(items: [
        item(.text, text: String(repeating: "абвгд еёжзи ", count: 1700)),
        item(.text, text: String(repeating: "i", count: 20_000)),
        item(.text, text: String(repeating: "\n.", count: 300)),
        item(.link, text: "https://" + String(repeating: "w", count: 500) + ".example.com/"),
        item(.file, paths: ["/x/" + String(repeating: "Ш", count: 250) + ".pdf"]),
        item(.text, text: "шестая не видна"),
    ], spaces: [ClipSpace(id: spaceA, name: String(repeating: "Очень длинное имя ", count: 8), colorID: "purple")],
       excluded: ["com.apple.Safari"])
}

@MainActor func checkScreen(out: String) async {
    var shots: [String: NSBitmapImageRep] = [:]
    for (name, scene) in [("empty", Fixture(ax: false)), ("full", fullFixture()), ("long", longFixture())] {
        LegacyFakeController.shared.show(scene)
        let before = await Stand.render(LegacyClipboardView(), "\(name)-before", out: out)
        let model = FakeClipboardModel(scene)
        let after = await Stand.render(ClipboardView(model: model), "\(name)-after", out: out)
        let diff = differingPixels(before, after)
        check(diff == 0, "экран «\(name)» до и после: отличается \(diff) из \(after.pixelsWide * after.pixelsHigh) пикселей")
        check(model.calls.contains("refreshPermissions"), "экран «\(name)» при открытии спросил разрешения у своей модели")
        shots[name] = after
    }
    // Экран на строках из состояния, как будет у вкладки центра. Обрезка заметна только у текста длиннее ~10 000 символов.
    var plain = longFixture()
    plain.items[0].text = String(plain.items[0].text!.prefix(8000))
    for (name, fixture) in [("full", fullFixture()), ("long-8000", plain)] {
        LegacyFakeController.shared.show(fixture)
        let before = await Stand.render(LegacyClipboardView(), "\(name)-wire-before", out: out)
        let model = FakeClipboardModel(fixture)
        model.showsWireRows = true
        let after = await Stand.render(ClipboardView(model: model), "\(name)-wire-after", out: out)
        let diff = differingPixels(before, after)
        check(diff == 0, "экран «\(name)» на строках из состояния: отличается \(diff) пикселей")
    }
    LegacyFakeController.shared.show(longFixture())
    let hugeBefore = await Stand.render(LegacyClipboardView(), "huge-wire-before", out: out)
    let huge = FakeClipboardModel(longFixture())
    huge.showsWireRows = true
    let hugeDiff = differingPixels(hugeBefore, await Stand.render(ClipboardView(model: huge), "huge-wire-after", out: out))
    check(hugeDiff < 4000, "текст 20 000 символов на строках из состояния: известный сдвиг усечения, \(hugeDiff) пикселей")

    let detector = differingPixels(shots["empty"]!, shots["full"]!)
    check(detector > 1000, "сравнение видит разницу: пустой и полный экран отличаются на \(detector) пикселей")
}

@main
enum Main {
    static func main() {
        setbuf(stdout, nil)
        let out = CommandLine.arguments[1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            checkRoundTrip()
            checkState()
            checkRefusals()
            checkAccepted()
            await checkScreen(out: out)
            print(failures == 0 ? "ГОТОВО: всё верно" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
