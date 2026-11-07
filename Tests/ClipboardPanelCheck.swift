import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

// Панель «Буфера»: клики, клавиши, категории, поиск, снимки. Запуск: Tests/run-clipboard-panel-check.sh
// Хранилище во временной папке с выдуманным ключом, окно прозрачное и за экраном, настройки в своём suite.
// Настоящие связка, история и буфер обмена здесь не упоминаются: страж в скрипте.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// MARK: - Клики

func checkTracker() {
    let a = UUID(), b = UUID()
    let t0: TimeInterval = 100_000
    var tracker = ClipClickTracker()
    check(ClipClickTracker.pasteWindow == 0.45, "окно двойного клика 0,45 с")
    check(tracker.click(a, at: t0) == .select, "первый клик только выделяет")
    check(tracker.click(a, at: t0 + 0.44) == .paste, "второй через 0,44 с вставляет")
    check(tracker.click(a, at: t0 + 0.50) == .select, "третий сразу после вставки не вставляет")

    tracker = ClipClickTracker()
    _ = tracker.click(a, at: t0)
    check(tracker.click(a, at: t0 + 0.46) == .select, "второй через 0,46 с только выделяет")
    check(tracker.click(a, at: t0 + 0.46 + 0.44) == .paste, "поздний клик начал отсчёт заново")

    tracker = ClipClickTracker()
    _ = tracker.click(a, at: t0)
    check(tracker.click(b, at: t0 + 0.1) == .select, "другая карточка только выделяет")
    check(tracker.click(a, at: t0 + 0.2) == .select, "возврат на первую не вставляет: отсчёт начат на другой")
    check(tracker.click(a, at: t0 + 0.3) == .paste, "двойной клик после этого работает")

    tracker = ClipClickTracker()
    _ = tracker.click(a, at: t0)
    tracker.reset()
    check(tracker.click(a, at: t0 + 0.1) == .select, "после сброса отсчёта нет")

    tracker = ClipClickTracker()
    _ = tracker.click(a, at: t0)
    check(tracker.click(a, at: t0 - 0.1) == .select, "время назад не считается вторым кликом")
}

@MainActor func checkModelClicks() {
    let model = ClipboardPanelModel()
    model.allItems = ClipPanelFixture.items()
    var pasted: [UUID] = []
    model.onPaste = { pasted.append($0.id) }
    let list = model.visible
    let t0: TimeInterval = 500
    model.click(list[2], at: 2, time: t0)
    check(model.selected == 2 && pasted.isEmpty, "первый клик выделил сразу и не вставил")
    model.click(list[2], at: 2, time: t0 + 0.2)
    check(pasted == [list[2].id], "второй клик вставил ту же запись")
    model.click(list[2], at: 2, time: t0 + 0.3)
    check(pasted.count == 1, "третий быстрый клик не вставил повторно")
    model.click(list[3], at: 3, time: t0 + 0.4)
    check(model.selected == 3 && pasted.count == 1, "другая карточка только выделена")
    let before = model.scrollRequest
    model.click(list[4], at: 4, time: t0 + 5)
    check(model.scrollRequest == before, "клик не прокручивает ленту: карточка не уезжает между кликами")
    model.move(1)
    check(model.scrollRequest == list[5].id, "стрелка прокручивает к выбранной")
    model.query = "m.docker"
    check(model.selected == 0, "смена запроса вернула выбор на первую")
    let found = model.visible[0]
    model.click(found, at: 0, time: t0 + 10)
    model.query = "m.docke"
    model.click(found, at: 0, time: t0 + 10.1)
    check(pasted.count == 1, "смена запроса сбросила отсчёт клика")
}

// MARK: - Клавиши

let esc: UInt16 = 53, enter: UInt16 = 36, tab: UInt16 = 48, left: UInt16 = 123, right: UInt16 = 124, del: UInt16 = 51, space: UInt16 = 49

@MainActor func checkKeys() {
    let model = ClipboardPanelModel()
    model.allItems = ClipPanelFixture.items()
    model.spaces = ClipPanelFixture.spaces
    var pasted: [UUID] = []
    var closed = 0
    model.onPaste = { pasted.append($0.id) }
    model.onClose = { closed += 1 }
    let list = model.visible

    check(!model.searchOpen, "панель открывается без раскрытого поиска")
    check(model.handleKey(ClipPanelKey(code: del, text: "\u{7f}")), "Delete при закрытом поиске поле не трогает")
    check(model.handleKey(ClipPanelKey(code: space, text: " ")), "пробел при закрытом поиске поиск не открывает")
    check(model.handleKey(ClipPanelKey(code: 126, text: "\u{F700}")), "стрелка вверх при закрытом поиске поле не трогает")
    check(!model.searchOpen && model.query.isEmpty, "поиск всё ещё закрыт")
    check(!model.handleKey(ClipPanelKey(code: 0, text: "ф")) && model.searchOpen, "русская буква идёт в поле и раскрывает поиск")
    model.reset()
    check(!model.handleKey(ClipPanelKey(code: 0, text: "")) && model.searchOpen, "мёртвая клавиша идёт в поле и раскрывает поиск")
    model.reset()
    model.query = "а"
    check(model.searchOpen, "текст в поле мимо клавиш тоже раскрывает поиск")
    model.query = "Текст"
    check(!model.handleKey(ClipPanelKey(code: del, text: "\u{7f}")), "в поиске Delete правит запрос")
    check(!model.handleKey(ClipPanelKey(code: space, text: " ")), "в поиске пробел идёт в запрос")
    let found = model.visible
    check(model.handleKey(ClipPanelKey(code: right, text: "\u{F703}")) && model.selected == 1, "→ работает во время поиска")
    check(model.handleKey(ClipPanelKey(code: left, text: "\u{F702}")) && model.selected == 0, "← работает во время поиска")
    check(model.handleKey(ClipPanelKey(code: enter, text: "\r")) && pasted == [found[0].id], "⏎ вставляет во время поиска")
    check(model.handleKey(ClipPanelKey(code: 19, command: true, text: "2")) && pasted.last == found[1].id, "⌘2 работает во время поиска")
    model.click(found[1], at: 1, time: 900)
    check(model.selected == 1, "клик по карточке работает во время поиска")
    check(model.handleKey(ClipPanelKey(code: tab, text: "\t")) && model.tab == model.spaces[0].id, "⇥ переключает вкладку во время поиска")
    check(model.handleKey(ClipPanelKey(code: tab, shift: true, text: "\t")) && model.tab == nil, "⇧⇥ назад")

    check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && !model.searchOpen && model.query.isEmpty && closed == 0, "Esc сначала закрыл поиск, панель осталась")
    check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && closed == 1, "второй Esc закрыл панель")

    model.reset()
    check(model.handleKey(ClipPanelKey(code: 18, command: true, text: "1")) && pasted.last == list[0].id, "⌘1 без поиска")
    check(!ClipPanelKey(code: 0, command: true, text: "a").isPlainText, "⌘A не буква для поиска")
    check(!ClipPanelKey(code: 0, control: true, text: "a").isPlainText, "⌃A не буква для поиска")
    check(ClipPanelKey(code: 0, shift: true, text: "A").isPlainText, "заглавная буква для поиска годится")

    model.openSearch()
    check(model.searchOpen && model.query.isEmpty, "значок раскрыл пустой поиск")
    model.closeSearch()
    model.typeIntoSearch("x")
    model.typeIntoSearch("y")
    check(model.query == "xy" && model.searchOpen, "запасной путь набора копит буквы")
    let scrollBefore = model.scrollTick
    let shownBefore = model.shownAt
    model.selected = 3
    model.reset()
    check(!model.searchOpen && model.query.isEmpty && model.editor == nil, "новый показ панели без поиска и окошка")
    check(model.scrollTick > scrollBefore && model.scrollRequest == model.visible.first?.id, "новый показ возвращает ленту к началу")
    check(model.shownAt > shownBefore, "новый показ обновляет отсчёт «N минут назад»")
    model.storeError = "нет хранилища"
    check(!model.canAddSpace, "без хранилища кнопка + не обещает создать")
    model.beginCreate()
    check(model.editor == nil, "без хранилища окошко создания не открывается")
    model.storeError = nil

    check(Set(ClipPanelText.hints.map(\.key)).isSuperset(of: ["←→", "⏎", "⌘1–9", "⇥", "Esc"]), "подсказки ушли в меню, все на месте")
}

// MARK: - Категории на настоящем контроллере и временном хранилище

@MainActor func checkSpaces() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-panel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = SymmetricKey(size: .bits256)
    let store = ClipboardStore(directory: dir, key: key, limit: 10)
    let controller = ClipboardController.shared
    controller.attach(store)
    let model = ClipboardPanelHost.shared.makeModel(controller)
    model.spaces = controller.spaces
    var closed = 0
    model.onClose = { closed += 1 }
    let enterKey = ClipPanelKey(code: enter, text: "\r")
    let escKey = ClipPanelKey(code: esc, text: "\u{1b}")

    model.beginCreate()
    check(model.editor?.mode == .create, "+ открыл окошко")
    check(ClipPalette.all.count == 9, "в окошке 9 цветов палитры")
    check(model.handleKey(enterKey) && model.editor != nil && store.spaces.isEmpty, "пустое имя: Enter не создаёт, окошко открыто")
    model.editor?.name = "   "
    model.commitEditor()
    check(model.editor != nil && store.spaces.isEmpty, "имя из пробелов не создаёт")
    check(!model.handleKey(ClipPanelKey(code: 0, text: "a")), "буква в окошке идёт в его поле")
    check(!model.handleKey(ClipPanelKey(code: right, text: "\u{F703}")), "стрелка в окошке двигает курсор, не карточку")
    check(!model.handleKey(ClipPanelKey(code: 18, command: true, text: "1")), "⌘1 в окошке не вставляет запись")
    check(model.handleKey(escKey) && model.editor == nil && closed == 0, "Esc закрыл окошко, а не панель")

    model.beginCreate()
    model.editor?.name = "  пароли  "
    model.editor?.colorID = "green"
    check(model.handleKey(enterKey) && model.editor == nil, "Enter создал и закрыл окошко")
    check(store.spaces.map(\.name) == ["пароли"] && store.spaces[0].colorID == "green", "пространство в хранилище, имя без пробелов, цвет выбранный")
    check(model.spaces.map(\.name) == ["пароли"], "панель увидела новое пространство")
    let id = store.spaces[0].id

    model.beginEdit(model.spaces[0])
    model.editor?.name = "коды"
    model.commitEditor()
    check(store.spaces[0].name == "коды" && store.spaces[0].colorID == "green" && model.spaces[0].name == "коды", "переименовано, цвет прежний")
    model.beginEdit(model.spaces[0])
    model.editor?.colorID = "purple"
    model.commitEditor()
    check(store.spaces[0].colorID == "purple" && store.spaces[0].name == "коды" && model.spaces[0].colorID == "purple", "цвет сменён, имя прежнее")

    let reread = ClipboardStore(directory: dir, key: key, limit: 10)
    check(reread.spaces == store.spaces, "формат прежний: хранилище открывается заново, пространство на месте")

    // Удаление: записи возвращаются в историю, сверх лимита самые старые удаляются, и подпись это говорит.
    for i in 0..<12 { store.ingest(ClipSnapshot(types: ["public.utf8-plain-text"], text: "запись \(i)")) }
    let pinned = Array(store.items.suffix(2).map(\.id))   // две самые старые из 10 оставшихся
    for item in pinned { store.pin(item, to: id) }
    for i in 12..<14 { store.ingest(ClipSnapshot(types: ["public.utf8-plain-text"], text: "запись \(i)")) }
    model.allItems = store.items
    model.limit = store.limit
    let predicted = ClipSpaceDeletion.droppedCount(items: store.items, space: id, limit: store.limit)
    check(store.items.count == 12 && predicted == 2, "до удаления 12 записей, предсказано к удалению 2 (есть \(store.items.count), \(predicted))")
    let summary = ClipSpaceDeletion.summary(items: store.items, space: id, limit: store.limit)
    check(summary == "2 записи вернутся в историю. Лимит истории 10: 2 самые старые записи удалятся навсегда.", "подпись честная: \(summary)")

    model.selectTab(id)
    model.beginDelete(model.spaces[0])
    check(model.handleKey(enterKey) && store.spaces.count == 1, "Enter удаление не подтверждает")
    check(model.handleKey(ClipPanelKey(code: 0, text: "a")) && model.query.isEmpty, "буквы при подтверждении не уходят в поиск")
    check(model.handleKey(escKey) && store.spaces.count == 1 && closed == 0, "Esc отменил удаление")
    model.beginDelete(model.spaces[0])
    let total = store.items.count
    model.confirmDelete()
    check(store.spaces.isEmpty && model.spaces.isEmpty, "пространство удалено")
    check(store.items.count == total - predicted, "из \(total) записей ушло ровно предсказанное: осталось \(store.items.count)")
    check(store.items.allSatisfy { $0.spaceID == nil }, "оставшиеся записи снова в истории")
    check(model.tab == nil && model.editor == nil, "открытая вкладка удалённого пространства сменилась на историю")

    // Лимит не задет: не теряется ничего.
    let second = store.addSpace(name: "x", colorID: "blue")
    store.delete(store.items[0].id)
    store.pin(store.items[0].id, to: second.id)
    let kept = store.items.map(\.id)
    check(ClipSpaceDeletion.droppedCount(items: store.items, space: second.id, limit: store.limit) == 0, "в лимите: к удалению 0")
    check(ClipSpaceDeletion.summary(items: store.items, space: second.id, limit: store.limit) == "1 запись вернётся в историю.", "подпись для одной записи")
    store.deleteSpace(second.id)
    check(store.items.map(\.id) == kept, "в лимите все записи на месте")
    check(ClipSpaceDeletion.summary(items: [], space: second.id, limit: 10) == "Записей в нём нет.", "подпись пустого пространства")
    controller.detachStore()
}

// MARK: - Перетаскивание

/// Данные провайдера по типу, как их запросит программа. nil — данных нет.
func loaded(_ provider: NSItemProvider, _ type: String) async -> Data? {
    await withCheckedContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
    }
}

/// Сверх своего типа в провайдере ничего, что содержит номер записи.
func exposesID(_ provider: NSItemProvider, _ id: UUID) async -> Bool {
    let text = id.uuidString
    for type in provider.registeredTypeIdentifiers {
        guard let data = await loaded(provider, type) else { continue }
        if String(decoding: data, as: UTF8.self).uppercased().contains(text) { return true }
        if type != ClipDrag.recordType.identifier, data.range(of: ClipDrag.data(for: id)) != nil { return true }
    }
    return false
}

func hex(_ data: Data?) -> String { data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "нет" }

@MainActor func checkDrag() async {
    let now = Date()
    func fresh(_ kind: ClipKind, _ text: String? = nil, paths: [String]? = nil) -> ClipItem {
        ClipPanelFixture.entry(kind, text, source: nil, ago: 60, now: now, paths: paths)
    }
    let refuse: @Sendable () -> Data? = { nil }
    let plain = UTType.utf8PlainText.identifier

    // Текст
    let text = fresh(.text, "Обычный текст записи")
    let textDrag = ClipDrag.provider(for: text, loadImage: refuse)
    check(textDrag.registeredTypeIdentifiers.contains(plain), "текст: наружу есть строка")
    check(await loaded(textDrag, plain).map { String(decoding: $0, as: UTF8.self) } == text.text, "текст: наружу сам текст")
    check(!(await exposesID(textDrag, text.id)), "текст: наружу нет номера записи")
    check(textDrag.hasItemConformingToTypeIdentifier(ClipDrag.recordType.identifier), "текст: свой тип для броска на категорию есть")

    // Ссылка
    let address = "https://example.com/a?b=1"
    let link = fresh(.link, address)
    let linkDrag = ClipDrag.provider(for: link, loadImage: refuse)
    check(await loaded(linkDrag, plain).map { String(decoding: $0, as: UTF8.self) } == address, "ссылка: наружу адрес строкой")
    check(linkDrag.hasItemConformingToTypeIdentifier(UTType.url.identifier), "ссылка: наружу и как URL")
    check(!(await exposesID(linkDrag, link.id)), "ссылка: наружу нет номера записи")
    let script = fresh(.link, "javascript:alert(1)")
    let scriptDrag = ClipDrag.provider(for: script, loadImage: refuse)
    check(!scriptDrag.hasItemConformingToTypeIdentifier(UTType.url.identifier), "не настоящая ссылка: как URL не уходит")

    // Картинка: настоящее хранилище, те же байты, расшифровка только по запросу.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-drag-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ClipboardStore(directory: dir, key: SymmetricKey(size: .bits256))
    let image = ClipPanelFixture.image(fresh(.image))!
    let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
    store.ingest(ClipSnapshot(types: ["public.png"], imagePNG: png))
    let stored = store.items[0]
    let controller = ClipboardController.shared
    controller.attach(store)
    let model = ClipboardPanelHost.shared.makeModel(controller)
    model.allItems = store.items
    let before = store.items
    let drag = model.dragProvider(for: stored)
    check(drag.registeredTypeIdentifiers.contains(UTType.png.identifier), "картинка: наружу PNG")
    check(!drag.registeredTypeIdentifiers.contains(plain), "картинка: строки наружу нет")
    check(hex(await loaded(drag, UTType.png.identifier)) == hex(png), "картинка: наружу те же байты, что сохранены (хеш)")
    check(!(await exposesID(drag, stored.id)), "картинка: наружу нет номера записи")
    check(store.items == before, "вынос наружу не меняет историю и порядок")

    final class Counter: @unchecked Sendable { var calls = 0 }
    let counter = Counter()
    let lazy = ClipDrag.provider(for: stored, loadImage: { counter.calls += 1; return png })
    check(counter.calls == 0, "картинка: при начале перетаскивания не расшифровывается")
    _ = await loaded(lazy, UTType.png.identifier)
    check(counter.calls == 1, "картинка: расшифровка только по запросу, один раз")

    try? FileManager.default.removeItem(at: dir.appendingPathComponent(stored.imageFile!))
    let gone = model.dragProvider(for: stored)
    check(await loaded(gone, UTType.png.identifier) == nil, "картинка с пропавшим файлом: данных нет, ничего не выдумано")
    check(!gone.registeredTypeIdentifiers.contains(plain), "картинка с пропавшим файлом: подмены строкой нет")
    controller.detachStore()

    // Файл
    let real = dir.appendingPathComponent("настоящий.txt")
    try? Data("x".utf8).write(to: real)
    let missing = dir.appendingPathComponent("нет такого.txt")
    let fileDrag = ClipDrag.provider(for: fresh(.file, paths: [real.path]), loadImage: refuse)
    check(fileDrag.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), "файл: наружу файловый адрес")
    let fileData = await loaded(fileDrag, UTType.fileURL.identifier)
    check(fileData.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }?.path == real.path, "файл: адрес того самого файла")
    let noFile = ClipDrag.provider(for: fresh(.file, paths: [missing.path]), loadImage: refuse)
    check(noFile.registeredTypeIdentifiers == [ClipDrag.recordType.identifier], "пропавший файл: наружу ничего, только свой тип")
    let some = ClipDrag.provider(for: fresh(.file, paths: [missing.path, real.path]), loadImage: refuse)
    let someData = await loaded(some, UTType.fileURL.identifier)
    check(someData.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }?.path == real.path, "из нескольких файлов уходит первый живой")

    // Свой тип
    let id = UUID()
    check(ClipDrag.recordID(from: ClipDrag.data(for: id)) == id, "номер записи читается обратно")
    check(ClipDrag.recordID(from: Data(id.uuidString.utf8)) == nil, "номер текстом не принимается")
    check(!String(decoding: ClipDrag.data(for: id), as: UTF8.self).contains(id.uuidString), "свой тип несёт не текст")
    check(ClipDrag.recordType.identifier.hasPrefix("dyn.") && UTType(ClipDrag.recordType.identifier) != nil, "свой тип читается без объявления в Info.plist")
    check(ClipDrag.recordProvider(in: [textDrag])  != nil, "своя запись принимается по своему типу")
    check(ClipDrag.recordProvider(in: [NSItemProvider(object: "посторонний текст" as NSString)]) == nil, "посторонний текст не принимается")
    check(ClipDrag.recordProvider(in: [NSItemProvider(object: id.uuidString as NSString)]) == nil, "посторонний текст с номером записи не принимается")
}

/// Настоящая цель броска SwiftUI: панель в окне за экраном, события приходят от подставного сеанса перетаскивания.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let window: NSWindow
    var location = NSPoint.zero
    init(_ pasteboard: NSPasteboard, _ window: NSWindow) { self.pasteboard = pasteboard; self.window = window }
    var draggingDestinationWindow: NSWindow? { window }
    // Как у настоящего источника панели внутри программы, см. ClipPanelHostingView и checkDragSourceMask.
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor func checkDropTarget() async {
    let model = panelModel(theme: "vivid")
    var pins: [(UUID, UUID?)] = []
    model.onPin = { pins.append(($0, $1)) }
    let host = Stand.host(model, width: 1440)
    try? await Task.sleep(nanoseconds: 450_000_000)
    host.layoutSubtreeIfNeeded()
    guard let target = dropTargets(in: host).first else {
        check(false, "цель броска SwiftUI найдена")
        return
    }

    let own = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)"))
    let foreign = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)"))
    defer { own.releaseGlobally(); foreign.releaseGlobally() }
    let record = model.allItems[0]
    let item = NSPasteboardItem()
    item.setData(ClipDrag.data(for: record.id), forType: NSPasteboard.PasteboardType(ClipDrag.recordType.identifier))
    own.clearContents(); own.writeObjects([item])
    let textItem = NSPasteboardItem()
    textItem.setString(record.id.uuidString, forType: .string)
    foreign.clearContents(); foreign.writeObjects([textItem])

    // Ищем кнопку категории в ряду: сверху по центру ряда, шаг короче любой кнопки.
    let y = ClipPanelMetrics.panelHeight - ClipPanelMetrics.topPadding - ClipPanelMetrics.barHeight / 2
    let ownDrag = FakeDrag(own, Stand.window)
    var found: NSPoint?
    var proposal: NSDragOperation = []
    for x in stride(from: CGFloat(100), to: 1400, by: 12) {
        ownDrag.location = NSPoint(x: x, y: y)
        proposal = target.draggingEntered(ownDrag)
        if proposal != [] { found = ownDrag.location; break }
        target.draggingExited(ownDrag)
    }
    check(found != nil, "настоящая цель: своя запись над категорией принимается")
    guard let found else { return }
    check(proposal == .move, "настоящая цель: над категорией перенос, а не копирование, значка «+» нет (\(proposal.rawValue))")
    check(target.draggingUpdated(ownDrag) == .move, "настоящая цель: перенос и при движении над категорией")
    check(target.prepareForDragOperation(ownDrag) && target.performDragOperation(ownDrag), "настоящая цель: бросок своей записи выполнен")
    target.concludeDragOperation(ownDrag)
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(pins.count == 1 && pins.first?.0 == record.id && pins.first?.1 == ClipPanelFixture.spaces[0].id,
          "настоящая цель: запись закрепилась в категории под курсором (\(pins.count))")

    pins = []
    let foreignDrag = FakeDrag(foreign, Stand.window)
    foreignDrag.location = found
    check(target.draggingEntered(foreignDrag) == [], "настоящая цель: посторонний текст над категорией не принимается")
    _ = target.performDragOperation(foreignDrag)
    target.draggingExited(foreignDrag)
    try? await Task.sleep(nanoseconds: 200_000_000)
    check(pins.isEmpty, "настоящая цель: посторонний текст с номером записи ничего не закрепил")

    // Запись, которой нет в панели, тоже не закрепляется.
    model.acceptDroppedRecord(UUID(), on: ClipPanelFixture.spaces[0].id)
    check(pins.isEmpty, "чужой номер записи ничего не закрепил")
    Stand.window.contentView = nil
}

/// Что разрешает источник переноса в настоящем окне панели. Настоящего сеанса на стенде нет: вызов напрямую по селектору, сеанс источнику не нужен.
@MainActor func checkDragSourceMask() {
    let panel = ClipboardPanelHost.makePanel(ClipboardPanelModel())
    guard let view = panel.contentView?.subviews.first(where: { $0 is ClipPanelHostingView }) else {
        check(false, "в окне панели свой вид с разрешениями переноса")
        return
    }
    let selector = #selector(NSDraggingSource.draggingSession(_:sourceOperationMaskFor:))
    guard let found = class_getMethodImplementation(type(of: view), selector) else {
        check(false, "источник отвечает на запрос разрешений")
        return
    }
    typealias Mask = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> UInt
    let mask = unsafeBitCast(found, to: Mask.self)
    func allowed(_ context: NSDraggingContext) -> NSDragOperation { NSDragOperation(rawValue: mask(view, selector, nil, context.rawValue)) }
    check(allowed(.withinApplication) == [.copy, .move], "источник внутри программы разрешает перенос на категорию (\(allowed(.withinApplication).rawValue))")
    check(allowed(.outsideApplication) == .copy, "наружу только копия: программа получает содержимое, настоящий файл не переместится (\(allowed(.outsideApplication).rawValue))")
}

/// Цели SwiftUI: у каждой категории свой вид, слева направо. Отличаются от поля ввода типами: поле поиска тоже принимает брошенное.
/// Какую категорию выбрать, решает AppKit по виду, поэтому координата сеанса здесь ни на что не влияет.
@MainActor func dropTargets(in view: NSView) -> [NSView] {
    func targets(_ view: NSView) -> [NSView] { (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(targets) }
    return targets(view).filter { $0.registeredDraggedTypes.map(\.rawValue).contains("public.data") }
        .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
}

/// Где на снимке лежит цель: от левого верхнего угла, как у снимков.
@MainActor func shotRect(_ target: NSView, in host: NSView, margin: CGFloat = 0) -> CGRect {
    let rect = target.convert(target.bounds, to: host)
    let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    return CGRect(x: rect.minX - margin, y: top - margin, width: rect.width + margin * 2, height: rect.height + margin * 2)
}

@MainActor func snapshot(_ host: NSView, _ name: String? = nil, out: String) -> Shot {
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let name {
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
    return Shot(bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width)
}

/// Сколько точек участка заметно отличается на двух снимках.
func changed(_ a: Shot, _ b: Shot, in rect: CGRect) -> Int {
    var n = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let p = a.rgb(x, y), q = b.rgb(x, y)
            if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 0.08 { n += 1 }
        }
    }
    return n
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

/// Наведение и посадка на настоящей цели броска: события от подставного сеанса, панель за экраном.
@MainActor func checkDropEffects(out: String) async {
    for theme in ["graphite", "vivid"] {
        let suffix = theme == "graphite" ? "graphite" : "color"
        let model = panelModel(theme: theme)
        // Как в настоящей панели: запись получает категорию и видна в новом списке.
        model.onPin = { [weak model] id, space in
            guard let model, let index = model.allItems.firstIndex(where: { $0.id == id }) else { return }
            model.allItems[index].spaceID = space
        }
        let host = Stand.host(model, width: 1440)
        await pause(0.45)
        host.layoutSubtreeIfNeeded()
        let spaces = dropTargets(in: host)
        check(spaces.count == ClipPanelFixture.spaces.count, "\(suffix): все категории принимают перенос (\(spaces.count))")
        guard spaces.count >= 2 else { continue }
        let target = spaces[0]
        let own = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)"))
        let foreign = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)"))
        defer { own.releaseGlobally(); foreign.releaseGlobally() }
        func carry(_ id: UUID) {
            let item = NSPasteboardItem()
            item.setData(ClipDrag.data(for: id), forType: NSPasteboard.PasteboardType(ClipDrag.recordType.identifier))
            own.clearContents(); own.writeObjects([item])
        }
        let free = model.allItems.first { $0.spaceID == nil }!
        carry(free.id)
        let textItem = NSPasteboardItem()
        textItem.setString("посторонний текст", forType: .string)
        foreign.clearContents(); foreign.writeObjects([textItem])
        let drag = FakeDrag(own, Stand.window)

        // Запас под увеличение: вид растёт за свои границы.
        let rect = shotRect(target, in: host, margin: 4)
        let neighbour = shotRect(spaces[1], in: host)
        await pause(0.5)
        let rest = snapshot(host, out: out)

        // Наведение и возврат.
        _ = target.draggingEntered(drag)
        await pause(0.6)
        let hover = snapshot(host, "\(suffix)-drop-hover", out: out)
        check(changed(rest, hover, in: rect) > 200, "\(suffix): категория под курсором подсветилась (\(changed(rest, hover, in: rect)) точек)")
        check(changed(rest, hover, in: neighbour) == 0, "\(suffix): соседняя категория не сдвинулась и не подсветилась")
        target.draggingExited(drag)
        await pause(0.6)
        check(changed(rest, snapshot(host, out: out), in: rect) == 0, "\(suffix): курсор ушёл, категория вернулась к обычному виду")

        // Посторонние данные вид не меняют.
        let stranger = FakeDrag(foreign, Stand.window)
        check(target.draggingEntered(stranger) == [], "\(suffix): посторонний текст над категорией не принимается")
        await pause(0.4)
        check(changed(rest, snapshot(host, out: out), in: rect) == 0, "\(suffix): посторонний текст категорию не подсветил")
        target.draggingExited(stranger)

        // Посадка в общей вкладке: вспышка, точка на карточке, запись на месте.
        let order = model.visible.map(\.id)
        let index = order.firstIndex(of: free.id)!
        _ = target.draggingEntered(drag)
        await pause(0.4)
        let hovered = snapshot(host, out: out)
        check(target.prepareForDragOperation(drag) && target.performDragOperation(drag), "\(suffix): бросок выполнен")
        target.concludeDragOperation(drag)
        await pause(0.09)
        let flash = snapshot(host, "\(suffix)-drop-flash", out: out)
        check(changed(hovered, flash, in: rect) > 200, "\(suffix): при посадке категория вспыхнула сильнее наведения (\(changed(hovered, flash, in: rect)) точек)")
        await pause(1)
        let landed = snapshot(host, "\(suffix)-drop-landed", out: out)
        check(changed(rest, landed, in: rect) == 0, "\(suffix): вспышка погасла")
        check(model.allItems.first { $0.id == free.id }?.spaceID == ClipPanelFixture.spaces[0].id, "\(suffix): запись попала в категорию")
        check(model.visible.map(\.id) == order, "\(suffix): в общей вкладке запись осталась на месте")
        let origin = cardOrigin(index)
        let title = CGRect(x: origin.x + 14, y: origin.y + 6, width: 120, height: 22)
        check(changed(rest, landed, in: title) > 10, "\(suffix): на карточке появилась точка категории (\(changed(rest, landed, in: title)) точек)")

        // Посадка из вкладки другой категории: запись уходит, соседние смыкаются.
        model.selectTab(ClipPanelFixture.spaces[0].id)
        await pause(0.4)
        // Брошенная туда же, откуда взята, запись осталась бы: цель — соседняя категория.
        let inTab = model.visible.map(\.id)
        check(inTab.count >= 2, "\(suffix): во вкладке категории есть записи (\(inTab.count))")
        let beforeLeave = snapshot(host, out: out)
        carry(inTab[0])
        let next = dropTargets(in: host)[1]
        _ = next.draggingEntered(drag)
        _ = next.prepareForDragOperation(drag)
        _ = next.performDragOperation(drag)
        next.concludeDragOperation(drag)
        let cards = CGRect(x: 0, y: cardOrigin(0).y, width: 1440, height: ClipCard.height)
        await pause(0.1)
        let closing = snapshot(host, out: out)
        await pause(1)
        let closed = snapshot(host, "\(suffix)-drop-closed", out: out)
        check(model.visible.map(\.id) == Array(inTab.dropFirst()), "\(suffix): запись ушла из открытой вкладки, порядок соседних прежний")
        check(changed(beforeLeave, closed, in: cards) > 500, "\(suffix): лента перестроилась")
        check(changed(closing, closed, in: cards) > 200 && changed(closing, beforeLeave, in: cards) > 200,
              "\(suffix): соседние карточки смыкаются плавно, есть промежуточный кадр (\(changed(closing, closed, in: cards)) и \(changed(closing, beforeLeave, in: cards)) точек)")

        // Сжатый вид на время поиска: цветная точка подсвечивается так же.
        model.selectTab(nil)
        model.openSearch()
        await pause(0.5)
        carry(free.id)
        let dots = dropTargets(in: host)
        check(dots.count == ClipPanelFixture.spaces.count, "\(suffix): при поиске все точки принимают перенос (\(dots.count))")
        if let dot = dots.first {
            let dotRect = shotRect(dot, in: host, margin: 3)
            let quiet = snapshot(host, out: out)
            check(dot.draggingEntered(drag) == .move, "\(suffix): над точкой тоже перенос")
            await pause(0.6)
            let glow = snapshot(host, "\(suffix)-drop-hover-search", out: out)
            check(changed(quiet, glow, in: dotRect) > 100, "\(suffix): точка под курсором подсветилась (\(changed(quiet, glow, in: dotRect)) точек)")
            dot.draggingExited(drag)
            await pause(0.6)
            check(changed(quiet, snapshot(host, out: out), in: dotRect) == 0, "\(suffix): курсор ушёл, точка вернулась")
        }
        Stand.window.contentView = nil
    }
}

// MARK: - Закрытие панели

/// Окно панели на стенде: за экраном и без настоящей клавиатуры, чтобы не забрать её у программы автора. Ключевым оно притворяется.
final class StandPanel: NSPanel {
    var fakeKey = false
    /// Точный момент ухода: опрос из проверки опаздывает на свой шаг.
    var orderedOutAt = 0.0
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { fakeKey }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        fakeKey = true
        orderFront(sender)
    }
    override func orderOut(_ sender: Any?) {
        fakeKey = false
        orderedOutAt = ProcessInfo.processInfo.systemUptime
        super.orderOut(sender)
    }
}

@MainActor final class LeaveStand {
    let host: ClipboardPanelHost
    let model: ClipboardPanelModel
    let frame = CGRect(x: -10000, y: 300, width: 1440, height: ClipPanelMetrics.panelHeight)
    var panel: StandPanel?

    /// Настоящее содержимое панели в окне стенда. `wired` — модель из настоящего `makeModel`: у неё настоящий Esc.
    init(wired: Bool = false) {
        let host = ClipboardPanelHost()
        self.host = host
        model = wired ? host.makeModel(ClipboardController.shared) : panelModel(theme: "vivid")
        host.hidesOnOutsideClick = false
        host.standFrame = frame
        host.reducesMotion = { false }
        host.panelMaker = { [weak self] model in
            let real = ClipboardPanelHost.makePanel(model)
            let content = real.contentView
            real.contentView = nil
            let panel = StandPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.contentView = content
            self?.panel = panel
            return panel
        }
    }

    func open() async {
        host.present(model)
        await pause(0.3)
    }

    var settledOpen: Bool {
        guard let panel else { return false }
        return host.isVisible && panel.isVisible && panel.alphaValue == 1 && panel.frame == frame && !panel.ignoresMouseEvents
    }

    var settledGone: Bool {
        guard let panel else { return false }
        return !host.isVisible && !panel.isVisible && panel.alphaValue == 0
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

func waitUntil(_ timeout: Double = 3, _ test: () -> Bool) async -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while !test() {
        if ProcessInfo.processInfo.systemUptime - start > timeout { return false }
        await pause(0.01)
    }
    return true
}

@MainActor func checkPanelLeave() async {
    let clock = { ProcessInfo.processInfo.systemUptime }

    // Обычное закрытие: монитор снят сразу, окно уезжает и гаснет, колбэк один раз после ухода.
    let stand = LeaveStand()
    let picture = stand.model.allItems.first { $0.kind == .image }!
    var loads = 0
    let loader = stand.model.imageLoader
    stand.model.imageLoader = { loads += 1; return loader($0) }
    await stand.open()
    guard let panel = stand.panel else {
        check(false, "окно стенда создано")
        return
    }
    check(stand.settledOpen, "панель открылась: альфа \(panel.alphaValue), кадр \(panel.frame)")
    check(panel.frame.minX == -10000, "окно панели в проверке за экраном")
    check(stand.host.monitorsInstalled, "пока панель открыта, монитор клавиш стоит")
    _ = stand.model.image(picture)
    loads = 0

    struct Mark { var visible: Bool; var key: Bool; var alpha: CGFloat; var elapsed: Double }
    var marks: [Mark] = []
    var began = clock()
    stand.host.hide { marks.append(Mark(visible: panel.isVisible, key: panel.isKeyWindow, alpha: panel.alphaValue, elapsed: clock() - began)) }
    check(!stand.host.monitorsInstalled, "монитор клавиш снят сразу в начале закрытия")
    check(!stand.host.isVisible, "isVisible при уходе уже false: для всех панель закрыта")
    check(panel.isVisible && panel.alphaValue > 0.9, "окно ещё на экране, скрытия сразу нет")
    check(panel.ignoresMouseEvents, "клики по уезжающей панели не вставляют второй раз")
    check(marks.isEmpty, "колбэк не раньше конца анимации")
    var alphas: [CGFloat] = []
    var heights: [CGFloat] = []
    while marks.isEmpty, clock() - began < 3 {
        alphas.append(panel.alphaValue)
        heights.append(panel.frame.minY)
        _ = stand.model.image(picture)
        await pause(0.012)
    }
    check(zip(alphas, alphas.dropFirst()).allSatisfy { $0 >= $1 } && alphas.contains { $0 > 0.05 && $0 < 0.95 }, "панель гаснет постепенно: \(alphas.count) замеров, \(alphas.prefix(8))")
    check(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 } && heights.contains { $0 < stand.frame.minY - 1 && $0 > stand.frame.minY - 39 },
          "панель уезжает вниз постепенно: \(heights.prefix(8))")
    check(loads == 0, "пока панель уезжает, картинки в памяти (загрузок \(loads))")
    check(marks.count == 1, "колбэк пришёл один раз (\(marks.count))")
    if let mark = marks.first {
        check(!mark.visible, "в колбэке окна уже нет на экране")
        check(!mark.key, "в колбэке окно уже не ключевое")
        check(mark.alpha == 0, "в колбэке панель погасла (альфа \(mark.alpha))")
        check(mark.elapsed >= 0.13, "колбэк после анимации 0,16 с, прошло \(mark.elapsed)")
    }
    await pause(0.3)
    check(marks.count == 1, "колбэк не повторился")
    check(stand.settledGone, "после ухода окно скрыто, альфа 0")
    check(panel.frame.minY == stand.frame.minY - ClipboardPanelHost.slideDistance, "панель уехала ровно на \(ClipboardPanelHost.slideDistance) pt вниз (\(panel.frame.minY))")
    loads = 0
    _ = stand.model.image(picture)
    check(loads == 1, "картинки забыты по завершении ухода")

    // hide у скрытой панели: уходить нечему, колбэк сразу.
    var count = 0
    stand.host.hide { count += 1 }
    check(count == 1 && stand.settledGone, "hide у скрытой панели зовёт колбэк сразу")

    // Двойной hide: анимация одна, оба колбэка по разу в её конце.
    await stand.open()
    var first = 0, second = 0, third = 0
    stand.host.hide { first += 1 }
    await pause(0.08)
    stand.host.hide { second += 1 }
    stand.host.hide()
    stand.host.hide { third += 1 }
    check(first == 0 && second == 0 && third == 0 && !stand.host.isVisible, "повторный hide не завершает уход раньше времени")
    let doubled = await waitUntil { first > 0 }
    await pause(0.3)
    check(doubled && first == 1 && second == 1 && third == 1, "двойной hide: каждый колбэк один раз (\(first), \(second), \(third))")
    check(stand.settledGone, "после двойного hide панель скрыта")

    // Повторное открытие посреди закрытия: старое завершение панель не скрывает, старый колбэк не приходит.
    await stand.open()
    var stale = 0
    stand.host.hide { stale += 1 }
    await pause(0.07)
    let midAlpha = panel.alphaValue
    stand.host.present(stand.model)
    check(stand.host.isVisible && stand.host.monitorsInstalled && !panel.ignoresMouseEvents, "открытие посреди ухода сразу вернуло панель и монитор клавиш")
    check(panel.alphaValue >= midAlpha - 0.2 || midAlpha == 0, "панель поехала обратно с текущего места, без скачка в ноль (было \(midAlpha), стало \(panel.alphaValue))")
    await pause(0.5)
    check(stand.settledOpen, "старое завершение не скрыло заново показанную панель: альфа \(panel.alphaValue), кадр \(panel.frame), видна \(panel.isVisible)")
    check(stale == 0, "колбэк отменённого ухода не пришёл (\(stale))")
    // Следующий уход после отмены обычный.
    var after = 0
    stand.host.hide { after += 1 }
    let afterDone = await waitUntil { after > 0 }
    await pause(0.3)
    check(afterDone && after == 1 && stale == 0 && stand.settledGone, "следующий уход после отмены обычный (\(after), старый \(stale))")

    // Открыли и снова закрыли, пока старая анимация не кончилась: её завершение не обрывает новый уход.
    await stand.open()
    var oldLeave = 0, newLeave = 0
    stand.host.hide { oldLeave += 1 }
    await pause(0.12)
    stand.host.present(stand.model)
    let secondBegan = clock()
    var secondElapsed = 0.0
    stand.host.hide { newLeave += 1; secondElapsed = clock() - secondBegan }
    let secondDone = await waitUntil { newLeave > 0 }
    check(secondDone && secondElapsed >= 0.13 && oldLeave == 0 && newLeave == 1, "завершение старого ухода не оборвало новый: прошло \(secondElapsed), колбэки \(oldLeave) и \(newLeave)")
    await pause(0.3)
    check(stand.settledGone && oldLeave == 0 && newLeave == 1, "после нового ухода панель скрыта, колбэк один")

    // Открытие посреди ухода на другом экране: панель уходит с прежнего места и приезжает на новое целиком.
    await stand.open()
    var moved = 0
    stand.host.hide { moved += 1 }
    await pause(0.05)
    let otherScreen = stand.frame.offsetBy(dx: -3000, dy: 100)
    stand.host.standFrame = otherScreen
    stand.host.present(stand.model)
    await pause(0.5)
    check(stand.host.isVisible && panel.isVisible && panel.alphaValue == 1 && panel.frame == otherScreen && moved == 0, "открытие посреди ухода на другом экране: панель там, колбэка нет (\(panel.frame), \(moved))")
    stand.host.standFrame = stand.frame
    stand.host.hide()
    await pause(0.35)
    check(stand.settledGone, "после этого панель закрывается")

    // Быстрые открытия и закрытия подряд: каждое следующее отменяет предыдущее.
    var rapid = [Int](repeating: 0, count: 6)
    for i in rapid.indices {
        stand.host.present(stand.model)
        await pause(i % 2 == 0 ? 0 : 0.02)
        stand.host.hide { rapid[i] += 1 }
        await pause(i % 3 == 0 ? 0 : 0.03)
    }
    stand.host.present(stand.model)
    await pause(0.5)
    check(stand.settledOpen && rapid.allSatisfy { $0 == 0 }, "серия открыл-закрыл-открыл: панель открыта, старых колбэков нет \(rapid)")
    stand.host.hide { rapid[0] += 1 }
    await pause(0.02)
    let gone = await waitUntil { rapid[0] == 1 }
    check(gone && stand.settledGone, "после серии панель закрывается обычным порядком")
    await pause(0.3)
    check(rapid[0] == 1, "колбэк последнего ухода один")

    // Закрытие сразу после открытия: уезжает на 40 pt от места показа, а не от середины пути.
    stand.host.present(stand.model)
    await pause(0.04)
    var quick = 0
    stand.host.hide { quick += 1 }
    let quickDone = await waitUntil { quick > 0 }
    check(quickDone && stand.settledGone && panel.frame.minY == stand.frame.minY - ClipboardPanelHost.slideDistance, "закрытие посреди открытия: панель на месте ухода (\(panel.frame.minY))")
    await stand.open()
    check(stand.settledOpen, "следующее открытие после быстрого закрытия обычное")

    // Горячая клавиша: при открытой закрывает, во время ухода открывает снова.
    let controller = ClipboardController.shared
    stand.host.toggle(controller: controller)
    check(!stand.host.isVisible && panel.isVisible, "клавиша при открытой панели начала уход")
    await pause(0.05)
    stand.host.toggle(controller: controller)
    check(stand.host.isVisible, "клавиша во время ухода открывает панель снова")
    await pause(0.5)
    check(stand.settledOpen, "после этого панель открыта и осталась открытой")
    stand.host.toggle(controller: controller)
    let toggled = await waitUntil { stand.settledGone }
    check(toggled, "клавиша закрыла панель до конца")
    stand.host.toggle(controller: controller)
    await pause(0.3)
    check(stand.settledOpen, "клавиша при скрытой панели открывает")
    stand.host.hide()
    await pause(0.3)
    stand.close()

    // Esc идёт через настоящий обработчик модели; смена программы через настоящее уведомление.
    let wired = LeaveStand(wired: true)
    await wired.open()
    _ = wired.model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}"))
    check(!wired.host.isVisible && wired.panel?.isVisible == true && !wired.host.monitorsInstalled, "Esc закрывает тем же уходом")
    let escDone = await waitUntil { wired.settledGone }
    check(escDone, "Esc: панель ушла до конца")
    wired.host.hidesOnOutsideClick = true
    await wired.open()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    check(!wired.host.isVisible && wired.panel?.isVisible == true, "смена программы закрывает тем же уходом")
    let switched = await waitUntil { wired.settledGone }
    check(switched, "смена программы: панель ушла до конца")
    wired.close()

    // «Уменьшить движение»: без анимации, порядок тот же.
    let still = LeaveStand()
    still.host.reducesMotion = { true }
    await still.open()
    check(still.settledOpen, "уменьшенное движение: панель открыта сразу на месте")
    var stillCount = 0
    still.host.hide { stillCount += 1 }
    check(stillCount == 1 && still.settledGone, "уменьшенное движение: закрытие сразу, колбэк один раз")
    still.close()
}

/// Настоящий порядок вставки на подставном отправителе: настоящих событий нет, системный буфер не участвует.
@MainActor func checkPasteAfterLeaving() async {
    let clock = { ProcessInfo.processInfo.systemUptime }
    let stand = LeaveStand()
    await stand.open()
    guard let panel = stand.panel else {
        check(false, "окно стенда создано")
        return
    }
    struct Sent { var visible: Bool; var key: Bool; var elapsed: Double }
    var sent: [Sent] = []
    var began = clock()
    let send = { @MainActor in sent.append(Sent(visible: panel.isVisible, key: panel.isKeyWindow, elapsed: clock() - began)) }

    check(ClipboardController.focusPause > 0 && ClipboardController.focusPause <= 0.2, "пауза для фокуса небольшая: \(ClipboardController.focusPause)")
    ClipboardController.pasteAfterLeaving(stand.host, send: send)
    check(sent.isEmpty && panel.isVisible, "⌘V не уходит сразу")
    let goneFirst = await waitUntil { !panel.isVisible }
    let goneAt = panel.orderedOutAt - began
    check(goneFirst && sent.isEmpty, "⌘V не уходит вместе с orderOut: нужна пауза для фокуса")
    let arrived = await waitUntil { !sent.isEmpty }
    await pause(0.3)
    check(arrived && sent.count == 1, "⌘V ушёл один раз (\(sent.count))")
    if let mark = sent.first {
        check(!mark.visible && !mark.key, "к ⌘V окна нет на экране и оно не ключевое")
        check(mark.elapsed >= goneAt + ClipboardController.focusPause - 0.01, "⌘V через паузу после ухода: ушло в \(goneAt), ⌘V в \(mark.elapsed)")
        check(mark.elapsed >= ClipboardPanelHost.slideDuration - 0.03 + ClipboardController.focusPause, "⌘V после анимации и паузы: \(mark.elapsed)")
    }

    // Открыли панель посреди ухода: ⌘V попал бы в неё саму.
    await stand.open()
    sent = []
    began = clock()
    ClipboardController.pasteAfterLeaving(stand.host, send: send)
    await pause(0.06)
    stand.host.present(stand.model)
    await pause(0.6)
    check(sent.isEmpty && stand.settledOpen, "открыли посреди ухода: ⌘V не ушёл, панель открыта (\(sent.count))")

    // Открыли панель в паузе после ухода.
    sent = []
    ClipboardController.pasteAfterLeaving(stand.host, send: send)
    let gone = await waitUntil { !panel.isVisible }
    stand.host.present(stand.model)
    await pause(0.5)
    check(gone && sent.isEmpty && stand.settledOpen, "открыли в паузе после ухода: ⌘V не ушёл (\(sent.count))")

    // Открыли в паузе и сразу снова закрыли: окно уезжает, ⌘V старой вставки не должен попасть в него.
    sent = []
    ClipboardController.pasteAfterLeaving(stand.host, send: send)
    let goneAgain = await waitUntil { !panel.isVisible }
    stand.host.present(stand.model)
    stand.host.hide()
    await pause(0.5)
    check(goneAgain && sent.isEmpty && stand.settledGone, "открыли и закрыли в паузе: старый ⌘V не ушёл (\(sent.count))")
    stand.close()
}

/// Копия при перетаскивании: на цветной подложке углы дают подложку, синего нет. Настоящую копию рисует система, здесь её содержимое.
@MainActor func checkDragPreview(out: String) async {
    for theme in ["graphite", "vivid"] {
        let model = panelModel(theme: theme)
        let item = ClipPanelFixture.entry(.text, "Копия карточки при перетаскивании", source: nil, ago: 60, now: Date())
        let margin: CGFloat = 20
        let root = ZStack(alignment: .topLeading) {
            Color(red: 0, green: 1, blue: 0)
            ClipCard(item: item, number: 2, selected: true, searching: false, theme: model.theme, spaces: [], now: Date(),
                     model: model, isDragPreview: true)
                .offset(x: margin, y: margin)
        }
        .frame(width: ClipCard.width + margin * 2, height: ClipCard.height + margin * 2)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: ClipCard.width + margin * 2, height: ClipCard.height + margin * 2)
        Stand.window.setContentSize(host.frame.size)
        Stand.window.contentView = host
        try? await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(theme == "graphite" ? "graphite" : "color")-drag-preview.png"))
        let shot = Shot(bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width)
        Stand.window.contentView = nil

        // Сверка с самой подложкой, её байты зависят от цветового профиля снимка.
        let backdrop = shot.rgb(2, 2)
        check(backdrop.g > backdrop.r + 0.3 && backdrop.g > backdrop.b + 0.3, "\(theme): подложка зелёная")
        let green: (ClipRGB) -> Bool = { abs($0.r - backdrop.r) + abs($0.g - backdrop.g) + abs($0.b - backdrop.b) < 0.03 }
        let w = ClipCard.width, h = ClipCard.height
        let corners = [(margin + 1, margin + 1), (margin + w - 2, margin + 1), (margin + 1, margin + h - 2), (margin + w - 2, margin + h - 2)]
        check(corners.allSatisfy { green(shot.rgb($0.0, $0.1)) }, "\(theme): углы копии прозрачные, видна подложка")
        check(!green(shot.rgb(margin + w / 2, margin + 1)) && !green(shot.rgb(margin + w / 2, margin + h - 2)), "\(theme): края копии на месте, это сама карточка")
        let outside = shot.count(in: CGRect(x: 0, y: 0, width: w + margin * 2, height: margin - 1)) { !green($0) }
            + shot.count(in: CGRect(x: 0, y: margin, width: margin - 1, height: h)) { !green($0) }
        check(outside == 0, "\(theme): снаружи карточки ничего нет, рамки выбора нет (\(outside) точек)")
        let blue = shot.count(in: CGRect(x: 0, y: 0, width: w + margin * 2, height: h + margin * 2)) { $0.b > $0.r + 0.25 && $0.b > $0.g + 0.15 }
        check(blue == 0, "\(theme): синих точек нет (\(blue))")
    }
}

// MARK: - Подписи и цвет

func checkTexts() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let cases: [(TimeInterval, String)] = [
        (0, "только что"), (1, "1 секунду назад"), (3, "3 секунды назад"), (11, "11 секунд назад"), (31, "31 секунду назад"),
        (60, "1 минуту назад"), (4 * 60, "4 минуты назад"), (8 * 60, "8 минут назад"), (11 * 60, "11 минут назад"),
        (21 * 60, "21 минуту назад"), (22 * 60, "22 минуты назад"), (3600, "1 час назад"), (2 * 3600, "2 часа назад"),
        (5 * 3600, "5 часов назад"), (21 * 3600, "21 час назад"), (86400, "вчера"), (3 * 86400, "3 дня назад"), (5 * 86400, "5 дней назад"),
        (21 * 86400, "21 день назад"),
    ]
    for (seconds, expected) in cases {
        let text = ClipPanelText.ago(now.addingTimeInterval(-seconds), now: now)
        check(text == expected, "время: \(expected)" + (text == expected ? "" : ", а вышло \(text)"))
    }
    check(ClipPanelText.ago(now.addingTimeInterval(30), now: now) == "только что", "время из будущего не даёт минус")
}

func flat(_ count: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> [UInt8] {
    (0..<count).flatMap { _ in [r, g, b, a] }
}

@MainActor func checkTint() {
    let orange = ClipHeaderTint.dominant(rgba: flat(100, 240, 120, 60))
    check(orange.r > orange.g && orange.g > orange.b && !orange.isGray, "оранжевый значок даёт оранжевую шапку")
    check(orange.contrastWithWhite >= ClipHeaderTint.minContrast, "оранжевая шапка: белый текст читается, контраст \(orange.contrastWithWhite)")
    let yellow = ClipHeaderTint.dominant(rgba: flat(100, 255, 240, 80))
    check(yellow.contrastWithWhite >= ClipHeaderTint.minContrast, "жёлтая шапка затемнена: контраст \(yellow.contrastWithWhite)")
    check(yellow.r > yellow.b, "у жёлтой оттенок остался")
    let dark = ClipRGB(r: 0.1, g: 0.2, b: 0.5)
    check(ClipHeaderTint.readable(dark) == dark, "тёмный цвет не меняется")
    check(ClipHeaderTint.dominant(rgba: flat(100, 255, 255, 255)) == ClipHeaderTint.neutral, "белый значок: нейтральная шапка")
    check(ClipHeaderTint.dominant(rgba: flat(100, 240, 120, 60, 0)) == ClipHeaderTint.neutral, "прозрачный значок: нейтральная шапка")
    check(ClipHeaderTint.dominant(rgba: []) == ClipHeaderTint.neutral, "нет пикселей: нейтральная шапка")
    check(ClipHeaderTint.dominant(rgba: flat(95, 10, 10, 10) + flat(5, 250, 40, 40)) == ClipHeaderTint.neutral, "чёрный значок с цветной искрой: нейтральная шапка")
    let many = ClipHeaderTint.dominant(rgba: flat(70, 250, 250, 250) + flat(10, 230, 60, 50) + flat(10, 60, 180, 80) + flat(10, 250, 210, 50))
    check(!many.isGray && many.contrastWithWhite >= ClipHeaderTint.minContrast, "многоцветный значок на белом: шапка цветная")
    check(abs(many.r - many.g) > 0.1, "многоцветный значок: жёлтый не выигрывает у соседей такой же доли")
    let mixed = ClipHeaderTint.dominant(rgba: flat(30, 20, 60, 230) + flat(70, 250, 250, 250))
    check(mixed.b > mixed.r, "белый значок с синей заливкой: синяя шапка")
    check(ClipHeaderTint.neutral.isGray && ClipHeaderTint.graphite.isGray, "нейтральная и графитовая шапка серые")
    check(ClipHeaderTint.neutral.contrastWithWhite >= ClipHeaderTint.minContrast && ClipHeaderTint.graphite.contrastWithWhite >= ClipHeaderTint.minContrast, "на серых шапках белый читается")

    check(ClipSourceTint.color(nil) == ClipHeaderTint.neutral, "нет источника: нейтральная шапка")
    check(ClipSourceTint.color("local.utilitumus.test.no-such-app") == ClipHeaderTint.neutral, "программы нет: нейтральная шапка")

    let red = NSImage(size: NSSize(width: 64, height: 64))
    red.lockFocus()
    NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
    NSRect(x: 8, y: 8, width: 48, height: 48).fill()
    red.unlockFocus()
    let fromImage = ClipSourceTint.pixels(red).map(ClipHeaderTint.dominant)
    check(fromImage.map { $0.r > 0.5 && $0.g < 0.2 && $0.b < 0.2 } == true, "красная картинка с прозрачными полями: красная шапка")

    let item = ClipPanelFixture.entry(.text, "x", source: "com.apple.Safari", ago: 1, now: Date())
    check(ClipCard.headerColor(item, theme: .graphite) == ClipHeaderTint.graphite, "Графит: шапка серая, что бы ни было в значке")
}

@MainActor func checkGeometry() {
    let ratio = ClipCard.width / ClipCard.height
    check(ratio > 0.9 && ratio < 1.1, "карточка почти квадратная: \(ClipCard.width)×\(ClipCard.height)")
    check(ClipCard.width == 242 && ClipCard.height == 244, "карточка как в референсе: \(ClipCard.width)×\(ClipCard.height)")
    check(ClipPanelMetrics.panelHeight == 334, "панель как в референсе: \(ClipPanelMetrics.panelHeight)")
    // Подпись и номер не налезают друг на друга: «1526 символов · ещё 20 строк» входит без сжатия, самая длинная — со сжатием.
    let font = NSFont.systemFont(ofSize: ClipCard.captionSize)
    func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    check(width("1526 символов · ещё 20 строк") <= ClipCard.captionRoom, "обычная подпись входит рядом с ⌘5: \(width("1526 символов · ещё 20 строк")) из \(ClipCard.captionRoom)")
    let longest = "20000 символов · ещё 19999 строк"
    check(width(longest) * ClipCard.captionMinScale <= ClipCard.captionRoom, "самая длинная подпись входит со сжатием: \(width(longest)) × \(ClipCard.captionMinScale) из \(ClipCard.captionRoom)")
    let numberWidth = ("⌘9" as NSString).size(withAttributes: [.font: font]).width
    check(ClipboardPreview.textWidth - ClipCard.captionRoom >= numberWidth + 8, "место под номер: \(ClipboardPreview.textWidth - ClipCard.captionRoom) при номере \(numberWidth)")
    let model = ClipboardPanelModel()
    let panel = ClipboardPanelHost.makePanel(model)
    check(panel.styleMask.contains(.nonactivatingPanel), "панель не активирует приложение")
    check(panel.canBecomeKey && !panel.canBecomeMain, "панель берёт клавиатуру, но не становится главным окном")
    check(!panel.hidesOnDeactivate, "панель не прячется от неактивности: приложение и не активно")
    check(panel.sharingType == .none, "панель не видна при показе экрана")
    check(!panel.isVisible, "окно панели в проверке не показано")
}

// MARK: - Экран

@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 1440, height: ClipPanelMetrics.panelHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    static func host(_ model: ClipboardPanelModel, width: CGFloat) -> NSView {
        // Подложка вместо стекла: снимок окна за экраном стекло не рисует.
        let root = ClipboardPanelView(model: model)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))
            .preferredColorScheme(.dark)
            .frame(width: width, height: ClipPanelMetrics.panelHeight)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: ClipPanelMetrics.panelHeight)
        window.setContentSize(host.frame.size)
        window.contentView = host
        return host
    }

    static func render(_ model: ClipboardPanelModel, _ name: String, out: String, width: CGFloat = 1440) async -> Shot {
        let host = host(model, width: width)
        try? await Task.sleep(nanoseconds: 450_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        window.contentView = nil
        return Shot(bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width)
    }
}

struct Shot {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat

    /// Координаты в точках от левого верхнего угла.
    func rgb(_ x: CGFloat, _ y: CGFloat) -> ClipRGB {
        // Сырые байты: снимок вне экрана хранит значения sRGB как есть, а его метка профиля дисплея исказила бы их при переводе.
        var raw = [Int](repeating: 0, count: max(4, bitmap.samplesPerPixel))
        bitmap.getPixel(&raw, atX: Int(x * scale), y: Int(y * scale))
        return ClipRGB(r: Double(raw[0]) / 255, g: Double(raw[1]) / 255, b: Double(raw[2]) / 255)
    }

    func count(in rect: CGRect, where test: (ClipRGB) -> Bool) -> Int {
        var n = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) where test(rgb(x, y)) { n += 1 }
        }
        return n
    }
}

/// Где на снимке лежит карточка.
func cardOrigin(_ index: Int) -> CGPoint {
    CGPoint(x: 16 + ClipPanelMetrics.ringRoom + CGFloat(index) * (ClipCard.width + ClipPanelMetrics.cardGap),
            y: ClipPanelMetrics.topPadding + ClipPanelMetrics.barHeight + ClipPanelMetrics.barGap + ClipPanelMetrics.ringRoom)
}

func saturation(_ c: ClipRGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

/// Полоса шапки правее текста и левее значка: там только заливка.
func headerFill(_ shot: Shot, card: Int) -> ClipRGB {
    let o = cardOrigin(card)
    return shot.rgb(o.x + 165, o.y + ClipCard.headerHeight - 3)
}

@MainActor func panelModel(theme: String, items: [ClipItem]? = nil) -> ClipboardPanelModel {
    Kit.defaults.set(theme, forKey: DSTheme.storageKey)
    let model = ClipboardPanelModel()
    model.allItems = items ?? ClipPanelFixture.items()
    model.spaces = ClipPanelFixture.spaces
    model.imageLoader = ClipPanelFixture.image
    model.refreshTheme()
    return model
}

@MainActor func checkScreens(out: String) async {
    // Обычный вид и все виды карточек (первые пять и следующие за ними).
    for theme in ["graphite", "vivid"] {
        let suffix = theme == "graphite" ? "graphite" : "color"
        let model = panelModel(theme: theme)
        check(model.theme.rawValue == theme, "тема «\(model.theme.title)» прочитана из настроек")
        let normal = await Stand.render(model, "\(suffix)-normal", out: out)

        let cardCount = min(model.visible.count, 5)
        for i in 0..<cardCount {
            let fill = headerFill(normal, card: i)
            if theme == "graphite" {
                check(saturation(fill) < 0.02, "Графит: шапка \(i + 1) серая, разброс каналов \(saturation(fill))")
            }
            check(fill.contrastWithWhite >= ClipHeaderTint.minContrast - 0.2, "\(suffix): на шапке \(i + 1) белый читается, контраст \(fill.contrastWithWhite)")
            let o = cardOrigin(i)
            let textRect = CGRect(x: o.x + 14, y: o.y + 8, width: 50, height: 38)
            let white = normal.count(in: textRect) { min($0.r, $0.g, $0.b) > 0.85 }
            check(white > 20, "\(suffix): заголовок шапки \(i + 1) белый, ярких точек \(white)")
        }
        if theme == "vivid" {
            let colored = (0..<cardCount).filter { saturation(headerFill(normal, card: $0)) > 0.1 }
            check(colored.count >= 2, "цветная тема: шапки из значков цветные (\(colored.count) из \(cardCount))")
        }

        // Рамка выбранной: акцент без поиска, серая при поиске.
        let o = cardOrigin(0)
        let ringPoint = (o.x - 3, o.y + ClipCard.height / 2)
        let ring = normal.rgb(ringPoint.0, ringPoint.1)
        let backdrop = normal.rgb(cardOrigin(1).x - 3, cardOrigin(1).y + ClipCard.height / 2)
        check(abs(ring.r - backdrop.r) + abs(ring.g - backdrop.g) + abs(ring.b - backdrop.b) > 0.3, "\(suffix): у выбранной карточки рамка, у соседней нет")

        // Поиск: поле раскрыто, категории стали точками.
        let bar = CGRect(x: 0, y: ClipPanelMetrics.topPadding, width: 1440, height: ClipPanelMetrics.barHeight)
        let bright: (ClipRGB) -> Bool = { min($0.r, $0.g, $0.b) > 0.6 }
        let brightNormal = normal.count(in: bar, where: bright)
        model.openSearch()
        let search = await Stand.render(model, "\(suffix)-search", out: out)
        let brightSearch = search.count(in: bar, where: bright)
        check(brightSearch * 3 < brightNormal, "\(suffix): при поиске названий категорий нет: ярких точек \(brightSearch) против \(brightNormal)")
        let dots = search.count(in: bar) { saturation($0) > 0.3 && max($0.r, $0.g, $0.b) > 0.5 }
        check(dots > 100, "\(suffix): при поиске цветные точки и рамка поля на месте: \(dots)")
        let grayRing = search.rgb(ringPoint.0, ringPoint.1)
        check(saturation(grayRing) < 0.03 && grayRing.r > 0.4, "\(suffix): при поиске рамка выбранной серая, \(grayRing)")
        if theme == "vivid" {
            check(saturation(ring) > 0.1, "цветная тема: рамка без поиска акцентная, \(ring)")
        }

        model.query = "Текст"
        _ = await Stand.render(model, "\(suffix)-search-query", out: out)
        model.query = "нет такого текста"
        _ = await Stand.render(model, "\(suffix)-nothing-found", out: out)
        model.closeSearch()

        // Выделение в середине ленты.
        model.selected = 2
        _ = await Stand.render(model, "\(suffix)-selected", out: out)

        // Хвост ленты: ссылка без программы, номера кончились, «Заметки» со светлым значком.
        let tail = panelModel(theme: theme, items: Array(ClipPanelFixture.items().suffix(5)))
        _ = await Stand.render(tail, "\(suffix)-kinds-tail", out: out)

        let empty = panelModel(theme: theme, items: [])
        _ = await Stand.render(empty, "\(suffix)-empty", out: out)
        empty.storeError = "Не удалось открыть файл истории — история не ведётся, файл не тронут"
        _ = await Stand.render(empty, "\(suffix)-store-error", out: out)

        let editors = panelModel(theme: theme)
        editors.beginCreate()
        _ = await Stand.render(editors, "\(suffix)-editor-create", out: out)
        editors.beginEdit(ClipPanelFixture.spaces[0])
        _ = await Stand.render(editors, "\(suffix)-editor-edit", out: out)
        editors.limit = 5
        editors.beginDelete(ClipPanelFixture.spaces[1])
        _ = await Stand.render(editors, "\(suffix)-editor-delete", out: out)
        Stand.window.contentView = nil
    }

    // Экран поменьше: ряд категорий прокручивается, карточки те же.
    let small = panelModel(theme: "vivid")
    _ = await Stand.render(small, "color-normal-1280", out: out, width: 1280)
}

/// Настоящие буквы через поле и настоящие клики через жесты, без экрана и фокуса: события шлются прямо в окно.
@MainActor func checkLiveEvents() async {
    let model = panelModel(theme: "vivid")
    var pasted = 0
    model.onPaste = { _ in pasted += 1 }
    let host = Stand.host(model, width: 1440)
    try? await Task.sleep(nanoseconds: 450_000_000)
    host.layoutSubtreeIfNeeded()

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: ClipPanelMetrics.panelHeight - y) }
    func click(_ p: NSPoint) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: Stand.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            Stand.window.sendEvent(event!)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    let second = cardOrigin(1)
    let target = point(second.x + 100, second.y + 120)
    await click(target)
    check(model.selected == 1 && pasted == 0, "настоящий клик выделил вторую карточку и не вставил (выбрана \(model.selected), вставок \(pasted))")
    try? await Task.sleep(nanoseconds: 500_000_000)
    await click(target)
    check(model.selected == 1 && pasted == 0, "повторный клик через 0,5 с не вставил")
    await click(target)
    check(pasted == 1, "второй быстрый клик вставил (вставок \(pasted))")
    await click(target)
    check(pasted == 1, "третий быстрый клик не вставил повторно (вставок \(pasted))")

    // Настоящие клавиши в скрытое поле. Фокус ставит сама панель, и у окна без ключа тоже.
    func key(_ text: String) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: Stand.window.windowNumber, context: nil, characters: text,
                                         charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)
            Stand.window.sendEvent(event!)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
    check(Stand.window.firstResponder is NSTextView, "скрытое поле поиска держит клавиатуру с момента показа")
    check(!model.searchOpen, "до первой буквы поиск закрыт")
    await key("т")
    check(model.query == "т" && model.searchOpen, "буква раскрыла поиск с этой буквой (запрос «\(model.query)»)")
    await key("е")
    check(model.query == "те", "вторая буква дописалась, а не заменила первую (запрос «\(model.query)»)")
    await click(point(cardOrigin(0).x + 100, cardOrigin(0).y + 120))
    check(model.selected == 0, "клик по карточке во время поиска сработал")
    await key("к")
    check(model.query == "тек", "после клика по карточке буквы идут в поле (запрос «\(model.query)»)")
    // Окошко забирало фокус и вернуло: при возврате поле выделяет весь текст, следующая буква не должна его стереть.
    model.beginCreate()
    try? await Task.sleep(nanoseconds: 200_000_000)
    model.closeEditor()
    try? await Task.sleep(nanoseconds: 200_000_000)
    await key("с")
    check(model.query == "текс", "после окошка буква дописалась к запросу (запрос «\(model.query)»)")
    Stand.window.contentView = nil
}

@main
enum Main {
    static func main() {
        setbuf(stdout, nil)
        let out = CommandLine.arguments[1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            checkTracker()
            checkModelClicks()
            checkKeys()
            checkSpaces()
            checkTexts()
            checkTint()
            checkGeometry()
            await checkDrag()
            await checkLiveEvents()
            checkDragSourceMask()
            await checkDropTarget()
            await checkDropEffects(out: out)
            await checkPanelLeave()
            await checkPasteAfterLeaving()
            await checkDragPreview(out: out)
            await checkScreens(out: out)
            print(failures == 0 ? "ГОТОВО: всё верно" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
