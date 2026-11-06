import AppKit
import SwiftUI

// Заметки к обновлению на стенде за экраном. Запуск: Tests/run-store-notes-check.sh
// Аргументы: рабочая папка, папка PNG этой сборки, папка PNG сборки BASE.
// Файл собирается и из старых исходников: всё про заметки под `#if !BASE_BUILD`.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
let baseDir = URL(fileURLWithPath: CommandLine.arguments[3])
nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

struct Boom: Error {}

final class Stage: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalog = Data()
    var catalog: Data {
        get { lock.lock(); defer { lock.unlock() }; return _catalog }
        set { lock.lock(); _catalog = newValue; lock.unlock() }
    }
}

let stage = Stage()
let paths = SatellitePaths(appsDir: workRoot.appendingPathComponent("Apps"),
                           agentsDir: workRoot.appendingPathComponent("Agents"))

/// Запись каталога. `notes` nil — ключа нет совсем.
func entry(_ id: String, _ version: String, notes: Any? = nil) -> [String: Any] {
    var app: [String: Any] = ["id": id, "version": version, "minHub": "0.6.0",
                              "url": "https://example.com/App.zip", "sha256": "ab", "sizeMB": 2]
    if let notes { app["notes"] = notes }
    return app
}

func catalogData(_ apps: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": apps])
}

@MainActor func makeEnvironment() -> SatelliteEnvironment {
    SatelliteEnvironment(
        paths: paths,
        defaults: Kit.defaults,
        installer: SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { _ in throw Boom() }, verify: { _, _ in },
                                      link: SatelliteLink(quit: { _ in }, hello: { _ in })),
        commands: SatelliteCommands(
            status: { _ in LinkStatus(enabled: true, line: "Работает", needsSetup: 0) },
            setEnabled: { _, _ in },
            openWindow: { _ in }),
        loadCatalog: { stage.catalog },
        hubVersion: "0.6.0",
        modules: ModuleManager.shared)
}

// MARK: - Снимки

/// Тема Стора и системное оформление. Приложение всегда просит тёмное, системное здесь на случай просачивания в материалы.
struct Look {
    let name: String
    let theme: String
    let appearance: NSAppearance.Name
}

let dusk = Look(name: "dusk", theme: "dusk", appearance: .darkAqua)
let graphiteLight = Look(name: "graphite-light", theme: "graphite", appearance: .aqua)
let duskLight = Look(name: "dusk-light", theme: "dusk", appearance: .aqua)
let midnight = Look(name: "midnight", theme: "midnight", appearance: .darkAqua)

/// Самое узкое окно: `WindowMinSize(width: 840, height: 540)` в UtilitumusApp.
let wide = (name: "wide", width: CGFloat(980), height: CGFloat(680))
let narrow = (name: "narrow", width: CGFloat(840), height: CGFloat(540))

struct StoreWithSidebar: View {
    @State private var dashboard = false
    @State private var store = true
    @State private var about = false
    @State private var peeked: Module?
    @State private var selection = Module.awake

    var body: some View {
        HStack(spacing: 0) {
            DSSidebar(current: nil, showDashboard: $dashboard, showStore: $store, showAbout: $about,
                      peeked: $peeked, selection: $selection)
                .frame(width: DS.sidebarWidth)
            StoreView()
        }
    }
}

/// Окно только за экраном: x: -10000, без активации, сразу убирается.
@MainActor func snapshot(_ name: String, _ look: Look, width: CGFloat, height: CGFloat) async {
    Kit.defaults.set(look.theme, forKey: DSTheme.storageKey)
    let root = ZStack {
        DSBackground(module: .awake, neutral: true)
        StoreWithSidebar()
    }
    .environment(\.moduleControls, DSModuleControls.forEnvironment)
    .dsThemed()
    .frame(width: width, height: height)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: look.appearance)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    try? await Task.sleep(for: .seconds(0.4))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
}

/// Сцена: какие бандлы стоят и что отвечает каталог.
struct StandScene {
    let name: String
    let module: Module
    let bundle: String
    let installed: String?
    let available: String
}

let updateScene = StandScene(name: "update", module: .awake, bundle: "Awake", installed: "1.0.0", available: "2.0.0")
let upToDateScene = StandScene(name: "uptodate", module: .awake, bundle: "Awake", installed: "2.0.0", available: "2.0.0")
let absentScene = StandScene(name: "absent", module: .awake, bundle: "Awake", installed: nil, available: "2.0.0")
/// «Голос» на крупной рекомендации.
let featuredScene = StandScene(name: "featured", module: .voice, bundle: "Voice", installed: "1.0.0", available: "2.0.0")

@MainActor func prepare(_ scene: StandScene, notes: Any?) async {
    try? fm.removeItem(at: paths.appsDir)
    try! fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
    if let installed = scene.installed {
        let contents = paths.appsDir.appendingPathComponent(scene.bundle + ".app/Contents")
        try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": installed]
        check(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true), "бандл стенда \(scene.bundle) \(installed)")
    }
    stage.catalog = catalogData([entry(scene.module.rawValue, scene.available, notes: notes)])
    await SatelliteRegistry.shared.update()
}

/// Пара снимков, витрина и панель подробностей: `<метка>-<сцена>-<вид>-<размер>-shelf|detail.png`.
@MainActor func render(_ label: String, _ scene: StandScene, notes: Any?, looks: [Look], sizes: [(name: String, width: CGFloat, height: CGFloat)]) async {
    await prepare(scene, notes: notes)
    let store = StoreModel.shared
    for look in looks {
        for size in sizes {
            let name = "\(label)-\(scene.name)-\(look.name)-\(size.name)"
            await snapshot(name + "-shelf", look, width: size.width, height: size.height)
            store.open(scene.module)
            try? await Task.sleep(for: .seconds(0.3))
            await snapshot(name + "-detail", look, width: size.width, height: size.height)
            store.close()
            try? await Task.sleep(for: .seconds(0.3))
        }
    }
}

/// То, что снимается в обеих сборках: заметок нет.
@MainActor func renderPlain() async {
    await render("plain", updateScene, notes: nil, looks: [dusk, graphiteLight, duskLight, midnight], sizes: [wide, narrow])
    for scene in [upToDateScene, absentScene, featuredScene] {
        await render("plain", scene, notes: nil, looks: [dusk], sizes: [wide, narrow])
    }
}

// MARK: - Сравнение

struct Difference {
    var pixels = 0
    /// В пикселях снимка.
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var scale = CGFloat(1)
    var height: CGFloat { pixels == 0 ? 0 : CGFloat(maxY - minY + 1) / scale }
    var width: CGFloat { pixels == 0 ? 0 : CGFloat(maxX - minX + 1) / scale }
}

/// Попиксельно по байтам снимка. nil: файла нет или форматы разные.
func compare(_ a: URL, _ b: URL, pointWidth: CGFloat, rows: ClosedRange<CGFloat>? = nil) -> Difference? {
    guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b),
          let repA = NSBitmapImageRep(data: dataA), let repB = NSBitmapImageRep(data: dataB),
          repA.pixelsWide == repB.pixelsWide, repA.pixelsHigh == repB.pixelsHigh,
          repA.bytesPerRow == repB.bytesPerRow, repA.bitsPerPixel == repB.bitsPerPixel,
          let bytesA = repA.bitmapData, let bytesB = repB.bitmapData else { return nil }
    let bytesPerPixel = repA.bitsPerPixel / 8
    var difference = Difference()
    difference.scale = CGFloat(repA.pixelsWide) / pointWidth
    for y in 0..<repA.pixelsHigh {
        if let rows, !rows.contains(CGFloat(y) / difference.scale) { continue }
        let row = y * repA.bytesPerRow
        for x in 0..<repA.pixelsWide where memcmp(bytesA + row + x * bytesPerPixel, bytesB + row + x * bytesPerPixel, bytesPerPixel) != 0 {
            difference.pixels += 1
            difference.minX = min(difference.minX, x); difference.maxX = max(difference.maxX, x)
            difference.minY = min(difference.minY, y); difference.maxY = max(difference.maxY, y)
        }
    }
    return difference
}

/// Все пары снимков с такими именами совпадают. Падает и на отсутствующем файле: иначе нечего было бы сравнивать.
func expectIdentical(_ what: String, _ left: (URL, String), _ right: (URL, String), scene: StandScene, looks: [Look]) {
    var total = 0, files = 0, broken = 0
    for look in looks {
        for size in [wide, narrow] {
            for view in ["shelf", "detail"] {
                let suffix = "-\(scene.name)-\(look.name)-\(size.name)-\(view).png"
                guard let diff = compare(left.0.appendingPathComponent(left.1 + suffix),
                                         right.0.appendingPathComponent(right.1 + suffix), pointWidth: size.width) else {
                    broken += 1
                    continue
                }
                files += 1
                total += diff.pixels
                if diff.pixels > 0 { print("     \(suffix): \(diff.pixels)") }
            }
        }
    }
    check(total == 0 && broken == 0 && files > 0, "\(what): различий \(total) пикс. на \(files) снимках")
}

#if BASE_BUILD

@MainActor func runAll() async {
    SatelliteRegistry.standEnvironment = makeEnvironment()
    let notes = ["Новая заметка", "Вторая **заметка**"]
    let decoded = try? SatelliteCatalog.decode(catalogData([entry("awake", "2.0.0", notes: notes)]))
    check(decoded?.apps.first?.version == "2.0.0", "старый центр: каталог с заметками читается")
    let future = try? SatelliteCatalog.decode(catalogData([entry("awake", "2.0.0", notes: 42)]))
    check(future?.apps.first?.version == "2.0.0", "старый центр: заметкам любого вида всё равно")
    await renderPlain()
    await render("oldhub", updateScene, notes: notes, looks: [dusk], sizes: [wide, narrow])
    await render("oldhub", featuredScene, notes: notes, looks: [dusk], sizes: [wide, narrow])
    // Заодно показывает, что снимки повторяемы: другой каталог, тот же вид.
    for scene in [updateScene, featuredScene] {
        expectIdentical("старый центр не видит заметок (\(scene.name))", (pngDir, "plain"), (pngDir, "oldhub"), scene: scene, looks: [dusk])
    }
    print(failures == 0 ? "BASE: все проверки прошли" : "BASE: провалов \(failures)")
    exit(failures == 0 ? 0 : 1)
}

#else

func decodeNotes(_ notes: Any?) -> [String]? {
    let catalog = try? SatelliteCatalog.decode(catalogData([entry("awake", "2.0.0", notes: notes)]))
    return catalog?.apps.first?.notes
}

func decodingChecks() {
    check(decodeNotes(nil) == [], "ключа notes нет: заметок нет, каталог читается")
    check(decodeNotes([String]()) == [], "пустой список")
    check(decodeNotes(NSNull()) == [], "null")
    for (value, name) in [("строка" as Any, "строка"), (42 as Any, "число"), (["k": "v"] as Any, "объект"), (["ok", 1] as Any, "смесь типов")] {
        check(decodeNotes(value) == [], "notes не того типа (\(name)): заметок нет, каталог не отвергнут")
    }
    let unknown = try? SatelliteCatalog.decode(catalogData([entry("awake", "2.0.0").merging(["future": ["x": 1]]) { $1 }]))
    check(unknown?.apps.first?.notes == [], "незнакомый ключ в записи не мешает")
    let schema2 = Data(#"{"schema":2,"apps":[]}"#.utf8)
    check((try? SatelliteCatalog.decode(schema2)) == nil, "schema 2 по-прежнему отвергается")

    let many = (0..<100).map { "заметка \($0)" }
    check(decodeNotes(many) == Array(many.prefix(SatelliteCatalog.maxNotes)), "заметок не больше \(SatelliteCatalog.maxNotes), порядок сохранён")
    check(decodeNotes(["  ", "\n\t"] + many)?.first == "заметка 0" && decodeNotes(["  ", "\n\t"] + many)?.count == SatelliteCatalog.maxNotes,
          "пустые в предел не считаются")
    let exact = String(repeating: "ы", count: SatelliteCatalog.maxNoteLength)
    check(decodeNotes([exact]) == [exact], "заметка ровно в предел цела")
    let cut = decodeNotes([exact + "ы"])?.first ?? ""
    check(cut.unicodeScalars.count == SatelliteCatalog.maxNoteLength && cut.hasSuffix("…"), "длиннее предела: обрезана с многоточием")
    let huge = decodeNotes([String(repeating: "ы ", count: 200_000)])?.first ?? ""
    check(huge.unicodeScalars.count == SatelliteCatalog.maxNoteLength, "огромная заметка: тот же предел")
    check(decodeNotes(["  две\nстроки\t\u{2028}тут  "]) == ["две строки тут"], "переводы строк и пробелы схлопнуты в один пробел")
    check(decodeNotes(["a\u{202E}b\u{200B}c\u{0007}d\u{E000}e"]) == ["abcde"], "переворот текста, нулевая ширина, управляющие и личная зона убраны")
    let zalgo = "a" + String(repeating: "\u{0301}", count: 500) + "b"
    check(decodeNotes([zalgo]) == ["a\u{0301}\u{0301}b"], "знаки, наложенные друг на друга, ограничены")
    check(decodeNotes(["и\u{0306}"]) == ["и\u{0306}"], "обычная диакритика цела")
    let markup = "**жирный** [ссылка](https://example.com) <b>"
    check(decodeNotes([markup]) == [markup], "разметка хранится как есть: это просто текст")
}

@MainActor func layoutChecks() {
    // Если разметку разобрать, от ссылки останется одно слово.
    let link = "[ссылка](https://example.com)", word = "ссылка"
    func tileWidth(_ note: String) -> CGFloat { NSHostingView(rootView: StoreUpdateTeaser(note: note).fixedSize()).fittingSize.width }
    func detailWidth(_ note: String) -> CGFloat {
        NSHostingView(rootView: StoreUpdateNotes(version: "2.0.0", notes: [note], tint: .orange).fixedSize()).fittingSize.width
    }
    check(tileWidth(link) > tileWidth(word) + 60, "плитка: ссылка не разбирается (\(tileWidth(link)) против \(tileWidth(word)))")
    check(detailWidth(link) > detailWidth(word) + 60, "панель: ссылка не разбирается (\(detailWidth(link)) против \(detailWidth(word)))")

    // Панель 380 минус её отступы: длинная заметка растит строку, а не режется и не распирает ширину.
    func panelSize(_ note: String) -> NSSize {
        NSHostingView(rootView: StoreUpdateNotes(version: "2.0.0", notes: [note], tint: .orange).frame(width: 324)).fittingSize
    }
    let long = String(repeating: "длинное слово ", count: 14)
    check(panelSize(long).height > panelSize("коротко").height + 30, "панель: длинная заметка переносится (\(panelSize(long).height) против \(panelSize("коротко").height))")
    check(panelSize(long).width == 324 && panelSize(String(repeating: "ы", count: 200)).width == 324, "панель: ширина не растёт, и от слова без пробелов тоже")
}

let longNote = "Длинная заметка, которая целиком на плитку не влезет: " + String(repeating: "очень длинное описание изменений ", count: 5)
let solidNote = String(repeating: "Ы", count: 200)
let longNotes = [longNote, solidNote, "**жирный** [ссылка](https://example.com)",
                 "a" + String(repeating: "\u{0301}", count: 500) + "заметка с наложенными знаками", "Обычная короткая заметка"]

@MainActor func runAll() async {
    SatelliteRegistry.standEnvironment = makeEnvironment()
    let store = StoreModel.shared
    check(store.satellites === SatelliteRegistry.shared, "Стор работает с подставным реестром")
    decodingChecks()
    layoutChecks()

    // Без заметок: те же пиксели, что у сборки, где заметок ещё не было.
    await renderPlain()
    expectIdentical("нет заметок, есть обновление, против BASE", (pngDir, "plain"), (baseDir, "plain"), scene: updateScene, looks: [dusk, graphiteLight, duskLight, midnight])
    for scene in [upToDateScene, absentScene, featuredScene] {
        expectIdentical("нет заметок, \(scene.name), против BASE", (pngDir, "plain"), (baseDir, "plain"), scene: scene, looks: [dusk])
    }
    let empties: [(String, Any)] = [("empty", [String]()), ("blank", ["  ", "\n"]), ("wrongtype", 42)]
    for (label, notes) in empties {
        await render(label, updateScene, notes: notes, looks: [dusk], sizes: [wide, narrow])
        expectIdentical("notes «\(label)» против BASE", (pngDir, label), (baseDir, "plain"), scene: updateScene, looks: [dusk])
    }
    // Заметки есть, а обновления нет: показывать нечего.
    for scene in [upToDateScene, absentScene] {
        await render("idle", scene, notes: longNotes, looks: [dusk], sizes: [wide, narrow])
        check(store.updateNotes(scene.module).isEmpty, "\(scene.name): заметок к показу нет")
        expectIdentical("заметки в каталоге, \(scene.name), против BASE", (pngDir, "idle"), (baseDir, "plain"), scene: scene, looks: [dusk])
    }

    // Обновление с заметками.
    await render("notes", updateScene, notes: ["Просыпается быстрее", "Исправлен значок"], looks: [dusk, graphiteLight], sizes: [wide, narrow])
    check(store.updateNotes(.awake) == ["Просыпается быстрее", "Исправлен значок"], "обновление: заметки к показу есть")
    for look in [dusk, graphiteLight] {
        let suffix = "-update-\(look.name)-wide-detail.png"
        let diff = compare(pngDir.appendingPathComponent("notes" + suffix), pngDir.appendingPathComponent("plain" + suffix), pointWidth: wide.width)
        check((diff?.pixels ?? 0) > 0, "\(look.name): заметки видны в панели (\(diff?.pixels ?? 0) пикс.): сравнение не слепое")
    }

    // Длинные заметки: сетка не двигается, отличается только третья строка одной плитки.
    await render("long", updateScene, notes: longNotes, looks: [dusk, duskLight, graphiteLight, midnight], sizes: [wide, narrow])
    for look in [dusk, duskLight, graphiteLight, midnight] {
        for size in [wide, narrow] {
            let suffix = "-update-\(look.name)-\(size.name)-shelf.png"
            let diff = compare(pngDir.appendingPathComponent("long" + suffix), pngDir.appendingPathComponent("plain" + suffix), pointWidth: size.width)
            let tile = (size.width - DS.sidebarWidth - 2 * DS.pagePadding - 16) / 3
            check((diff?.pixels ?? 0) > 0 && (diff?.height ?? 99) <= 16 && (diff?.width ?? 999) <= tile,
                  "\(look.name) \(size.name): длинная заметка только в строке плитки (\(diff?.width ?? -1)×\(diff?.height ?? -1) pt, плитка \(tile))")
        }
    }
    await render("solid", updateScene, notes: [solidNote], looks: [dusk], sizes: [narrow])
    let solid = compare(pngDir.appendingPathComponent("solid-update-dusk-narrow-shelf.png"),
                        pngDir.appendingPathComponent("plain-update-dusk-narrow-shelf.png"), pointWidth: narrow.width)
    check((solid?.height ?? 99) <= 16, "слово без пробелов на плитке: \(solid?.width ?? -1)×\(solid?.height ?? -1) pt")

    // Крупная рекомендация: заметка в карточке, а ряд под карточкой (карточка кончается на 102 pt) остался на месте.
    await render("long", featuredScene, notes: longNotes, looks: [dusk], sizes: [wide, narrow])
    let narrowShelf = "-featured-dusk-narrow-shelf.png"
    let card = compare(pngDir.appendingPathComponent("long" + narrowShelf), pngDir.appendingPathComponent("plain" + narrowShelf), pointWidth: narrow.width, rows: 0...102)
    let shelf = compare(pngDir.appendingPathComponent("long" + narrowShelf), pngDir.appendingPathComponent("plain" + narrowShelf), pointWidth: narrow.width, rows: 103...290)
    check((card?.pixels ?? 0) > 0, "рекомендация: заметка в карточке (\(card?.pixels ?? -1) пикс.)")
    check(shelf?.pixels == 0, "рекомендация: ряд под карточкой на месте, различий \(shelf?.pixels ?? -1) пикс.")

    print(failures == 0 ? "Все проверки прошли" : "Провалов: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

#endif

try! fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
Task { @MainActor in await runAll() }
app.run()
