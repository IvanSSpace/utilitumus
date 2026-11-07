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
    // Настоящие клавиши на этом Mac не должны влиять на проверку: автор может держать ⌘ в другой программе.
    model.modifiers = { [] }
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
    check(model.editor == nil && model.spaceNameEdit == nil, "без хранилища + ничего не открывает")
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

    // + создаёт сразу: окошка нет, поле имени в самом ряду.
    check(ClipPalette.all.count == 9, "в палитре 9 цветов")
    model.beginCreate()
    check(model.editor == nil, "+ не открывает окошко")
    check(store.spaces.map(\.name) == ["Без названия"] && model.spaces.count == 1, "категория появилась сразу")
    check(model.spaceNameEdit?.id == store.spaces[0].id && model.spaceNameEdit?.text == "Без названия" && model.spaceNameEdit?.isNew == true, "сразу в правке, текст «Без названия»")
    check(store.spaces[0].colorID == ClipPalette.all[0].id, "цвет первый незанятый")
    check(model.tab == nil, "вкладка откроется только после ввода")
    check(!model.handleKey(ClipPanelKey(code: 0, text: "a")) && !model.searchOpen && model.query.isEmpty, "буква идёт в поле имени, поиск не открылся")
    check(!model.handleKey(ClipPanelKey(code: right, text: "\u{F703}")), "стрелка в поле двигает курсор, не карточку")
    check(!model.handleKey(ClipPanelKey(code: 18, command: true, text: "1")), "⌘1 в поле не вставляет запись")
    check(model.handleKey(escKey) && model.spaceNameEdit == nil && closed == 0, "Esc отменил создание, а не закрыл панель")
    check(store.spaces.isEmpty && model.spaces.isEmpty, "Esc удалил новую пустую категорию")
    model.beginCreate()
    model.spaceNameEdit?.text = "   "
    check(model.handleKey(enterKey) && model.spaceNameEdit == nil, "Enter закрыл поле")
    check(store.spaces.map(\.name) == ["Без названия"] && model.tab == store.spaces[0].id, "пустое имя оставило «Без названия», вкладка открылась")
    model.onDeleteSpace(store.spaces[0].id)
    model.selectTab(nil)
    model.beginCreate()
    model.spaceNameEdit?.text = "  пароли  "
    check(model.handleKey(enterKey) && model.spaceNameEdit == nil, "Enter сохранил")
    check(store.spaces.map(\.name) == ["пароли"] && model.spaces.map(\.name) == ["пароли"], "имя без пробелов в хранилище и панели")
    check(model.tab == store.spaces[0].id, "после ввода открыта вкладка новой категории")
    model.selectTab(nil)
    let id = store.spaces[0].id
    // Цвета: занятый пропускается, заняты все — по очереди.
    store.setColor(id, ClipPalette.all[0].id)
    controller.attach(store)
    model.spaces = controller.spaces
    model.beginCreate()
    check(store.spaces.last?.colorID == ClipPalette.all[1].id, "занятый цвет пропущен")
    model.cancelInlineEdit()
    let colorStore = (0..<ClipPalette.all.count).map { ClipSpace(id: UUID(), name: "\($0)", colorID: ClipPalette.all[$0].id) }
    let colorModel = ClipboardPanelModel()
    colorModel.spaces = colorStore
    var picked: String?
    colorModel.onAddSpace = { _, color, _ in
        picked = color
        colorModel.spaces.append(ClipSpace(id: UUID(), name: "x", colorID: color))
    }
    colorModel.beginCreate()
    check(picked == ClipPalette.nextID(after: colorStore.count), "заняты все: по очереди (\(picked ?? ""))")
    let lockedModel = ClipboardPanelModel()
    lockedModel.storeError = "нет хранилища"
    var added = 0
    lockedModel.onAddSpace = { _, _, _ in added += 1 }
    lockedModel.beginCreate()
    check(!lockedModel.canAddSpace && added == 0 && lockedModel.spaceNameEdit == nil, "без хранилища + ничего не делает")

    // Переименовать в том же поле: Esc не удаляет, пустое имя оставляет прежнее, вкладка не меняется.
    model.beginRename(model.spaces[0])
    check(model.spaceNameEdit?.isNew == false && model.spaceNameEdit?.text == "пароли", "«Переименовать» в том же поле")
    model.spaceNameEdit?.text = "другое"
    check(model.handleKey(escKey) && store.spaces[0].name == "пароли" && closed == 0, "Esc отменил только правку имени")
    model.beginRename(model.spaces[0])
    model.spaceNameEdit?.text = "  "
    model.commitInlineEdit()
    check(store.spaces[0].name == "пароли", "пустое имя оставило прежнее")
    model.beginRename(model.spaces[0])
    model.spaceNameEdit?.text = "коды"
    model.commitInlineEdit()
    check(store.spaces[0].name == "коды" && model.spaces[0].name == "коды" && model.tab == nil, "переименовано, вкладка не сменилась")

    // Окошко теперь только настройки: цвет и скрытие, букв не принимает.
    model.beginEdit(model.spaces[0])
    check(model.handleKey(ClipPanelKey(code: 0, text: "a")) && model.query.isEmpty, "в окошке букв нет: не уходят в поиск за его спиной")
    model.editor?.colorID = "purple"
    model.commitEditor()
    check(store.spaces[0].colorID == "purple" && store.spaces[0].name == "коды" && model.spaces[0].colorID == "purple", "цвет сменён, имя прежнее")
    model.beginEdit(model.spaces[0])
    check(model.handleKey(escKey) && model.editor == nil && closed == 0, "Esc закрыл окошко, а не панель")

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
/// Лента (порядок карточек) тоже цель, но лежит ниже ряда. Все цели SwiftUI регистрируют один `public.data`: своё содержимое отличает сам приёмник.
@MainActor func dropTargets(in view: NSView) -> [NSView] {
    allPanelTargets(in: view).filter { isInTopBar($0) }
}

@MainActor func allPanelTargets(in view: NSView) -> [NSView] {
    func targets(_ view: NSView) -> [NSView] { (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(targets) }
    return targets(view).filter { $0.registeredDraggedTypes.map(\.rawValue).contains("public.data") }
        .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
}

@MainActor func isInTopBar(_ view: NSView) -> Bool {
    view.convert(view.bounds, to: nil).minY > ClipPanelMetrics.panelHeight - ClipPanelMetrics.topPadding - ClipPanelMetrics.barHeight - 1
}

@MainActor func stripTarget(in view: NSView) -> NSView? { allPanelTargets(in: view).first { !isInTopBar($0) } }

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
        // Проверки хода анимации снимают кадры посреди движения: им нужна длительность, а скорость проверяет checkPanelSpeed.
        Kit.defaults.set(ClipPanelSpeed.normal.rawValue, forKey: ClipboardPanelHost.showSpeedKey)
        Kit.defaults.set(ClipPanelSpeed.normal.rawValue, forKey: ClipboardPanelHost.hideSpeedKey)
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
        check(mark.elapsed >= ClipPanelSpeed.normal.duration - 0.03 + ClipboardController.focusPause, "⌘V после анимации и паузы: \(mark.elapsed)")
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
                     model: model, concealed: false, isDragPreview: true)
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
    model.modifiers = { [] }
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
    model.beginEdit(ClipPanelFixture.spaces[0])
    try? await Task.sleep(nanoseconds: 200_000_000)
    model.closeEditor()
    try? await Task.sleep(nanoseconds: 200_000_000)
    await key("с")
    check(model.query == "текс", "после окошка буква дописалась к запросу (запрос «\(model.query)»)")
    Stand.window.contentView = nil
}

// MARK: - Перестановка

// MARK: - Несколько карточек

func checkSelectionLogic() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    let list = [a, b, c, d, e]
    var s = ClipSelection()
    check(!s.isMultiple && s.ids.isEmpty, "сначала выбора нет")
    s.extend(to: d, from: b, in: list)
    check(s.ids == [b, c, d] && s.anchor == b && s.isMultiple, "Shift: диапазон от текущей")
    s.extend(to: a, from: d, in: list)
    check(s.ids == [a, b] && s.anchor == b, "Shift в другую сторону: от того же якоря")
    check(s.ordered(in: list) == [a, b], "порядок как в ленте")
    s.reset()
    _ = s.toggle(c, current: a, in: list)
    check(s.ids == [a, c] && s.anchor == c, "⌘ добавил к текущей, якорь на добавленной")
    s.extend(to: e, from: c, in: list)
    check(s.ids == [c, d, e], "Shift после ⌘: диапазон от якоря")
    s.reset()
    _ = s.toggle(a, current: a, in: list)
    check(s.ids == [a] && !s.isMultiple, "⌘ по единственной: она остаётся, это не множество")
    let focus = s.toggle(b, current: a, in: list)
    check(focus == b && s.isMultiple, "⌘ добавил вторую")
    let back = s.toggle(b, current: b, in: list)
    check(back == a && s.ids == [a] && !s.isMultiple, "⌘ убрал её, выбор на оставшейся")
}

@MainActor func checkMultiSelect(out: String) async {
    let model = panelModel(theme: "vivid")
    var flags: NSEvent.ModifierFlags = []
    model.modifiers = { flags }
    var one: [UUID] = [], many: [[UUID]] = [], closed = 0
    model.onPaste = { one.append($0.id) }
    model.onPasteMany = { many.append($0.map(\.id)) }
    model.onClose = { closed += 1 }
    let list = model.visible
    let t: TimeInterval = 5000
    model.click(list[1], at: 1, time: t)
    flags = .shift
    model.click(list[3], at: 3, time: t + 0.1)
    check(model.selection.ids == Set(list[1...3].map(\.id)) && model.selected == 3 && one.isEmpty, "Shift+клик: диапазон, вставки нет")
    check(model.hasRing(list[1], at: 1) && model.hasRing(list[2], at: 2) && model.hasRing(list[3], at: 3) && !model.hasRing(list[0], at: 0), "рамка на каждой выбранной")
    model.click(list[3], at: 3, time: t + 0.2)
    model.click(list[3], at: 3, time: t + 0.25)
    check(one.isEmpty && many.isEmpty, "Shift+клик второй раз подряд не вставляет")
    flags = .command
    model.click(list[5], at: 5, time: t + 0.3)
    check(model.selection.ids.contains(list[5].id) && model.selection.ids.count == 4 && model.selected == 5, "⌘+клик добавил одну")
    model.click(list[5], at: 5, time: t + 0.35)
    check(!model.selection.ids.contains(list[5].id) && model.selection.ids.count == 3 && one.isEmpty && many.isEmpty, "⌘+клик убрал её и не вставил")
    flags = []
    // Обычный клик мимо группы сбрасывает сразу.
    model.click(list[7], at: 7, time: t + 1)
    check(!model.isMultiSelected && model.selected == 7, "обычный клик мимо группы: одна")
    // Shift-стрелки.
    model.selected = 2
    model.clearSelection()
    let shiftRight = ClipPanelKey(code: right, shift: true, text: "\u{F703}"), shiftLeft = ClipPanelKey(code: left, shift: true, text: "\u{F702}")
    check(model.handleKey(shiftRight) && model.handleKey(shiftRight), "Shift+→ забирает панель")
    check(model.selection.ids == Set(list[2...4].map(\.id)) && model.selected == 4, "Shift+→ расширяет")
    _ = model.handleKey(shiftLeft)
    check(model.selection.ids == Set(list[2...3].map(\.id)) && model.selected == 3, "Shift+← сжимает к якорю")
    // Enter вставляет все, слева направо.
    check(model.handleKey(ClipPanelKey(code: enter, text: "\r")) && many.last == list[2...3].map(\.id) && one.isEmpty, "Enter вставляет все выбранные слева направо")
    // Второй клик по выбранной вставляет все; первый сжимает, только если второго не было.
    many = []
    model.click(list[3], at: 3, time: t + 3)
    check(model.isMultiSelected, "первый клик по выбранной пока не сжимает")
    model.click(list[2], at: 2, time: t + 3.1)
    check(model.isMultiSelected && many.isEmpty, "клик по другой выбранной: это ещё не второй клик")
    model.click(list[2], at: 2, time: t + 3.2)
    check(many.last == list[2...3].map(\.id), "второй клик по одной из выбранных вставил все")
    model.click(list[3], at: 3, time: t + 10)
    await pause(ClipClickTracker.pasteWindow + 0.1)
    check(!model.isMultiSelected && model.selected == 3, "второго клика не было: выбор сжался до неё")
    // Esc, смена вкладки, фильтра, стрелка без Shift.
    _ = model.handleKey(shiftRight)
    check(model.isMultiSelected, "снова несколько")
    check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && !model.isMultiSelected && closed == 0, "Esc снял выбор, панель открыта")
    check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && closed == 1, "второй Esc закрыл панель")
    _ = model.handleKey(shiftRight)
    model.selectTab(ClipPanelFixture.spaces[0].id)
    check(!model.isMultiSelected, "смена вкладки сбрасывает")
    model.selectTab(nil)
    _ = model.handleKey(shiftRight)
    model.query = "а"
    check(!model.isMultiSelected, "смена фильтра сбрасывает")
    model.closeSearch()
    _ = model.handleKey(shiftRight)
    _ = model.handleKey(ClipPanelKey(code: right, text: "\u{F703}"))
    check(!model.isMultiSelected, "стрелка без Shift сбрасывает")
    // Перенос: только одна.
    _ = model.handleKey(shiftRight)
    let carried = model.selectedItems[0]
    let provider = model.dragProvider(for: carried)
    check(!model.isMultiSelected && model.selectedItem?.id == carried.id, "перенос сжал выбор до самой карточки")
    check(provider.registeredTypeIdentifiers.contains("public.utf8-plain-text") || !provider.registeredTypeIdentifiers.isEmpty, "и отдаёт её")
    // Клик по заголовку при группе правку не открывает.
    _ = model.handleKey(shiftRight)
    model.clickTitle(model.visible[model.selected], time: t + 20)
    check(model.titleEdit == nil, "заголовок при группе: без правки")
    model.clearSelection()
    flags = .shift
    model.clickTitle(model.visible[0], time: t + 30)
    check(model.titleEdit == nil && model.isMultiSelected, "Shift+клик по заголовку выбирает диапазон")
    flags = []
    model.clearSelection()

    // Удаление: подтверждение окошком, не модальным.
    var deleted: [UUID] = []
    model.onDelete = { deleted.append($0) }
    model.selected = 0
    _ = model.handleKey(shiftRight)
    _ = model.handleKey(shiftRight)
    check(model.handleKey(ClipPanelKey(code: del, command: true, text: "\u{7f}")) && deleted.isEmpty, "⌘⌫ при группе ничего не удалил сразу")
    if case .confirmDeleteRecords(let ids)? = model.editor?.mode { check(ids.count == 3, "спрашивает про все три") } else { check(false, "открыто подтверждение") }
    check(model.handleKey(ClipPanelKey(code: enter, text: "\r")) && deleted.isEmpty, "Enter удаление не подтверждает")
    let host = Stand.host(model, width: 1440)
    await pause(0.4)
    _ = snapshot(host, "color-multi-delete", out: out)
    model.confirmDelete()
    check(deleted.count == 3 && model.editor == nil && !model.isMultiSelected, "подтвердили: удалены три")
    Stand.window.contentView = nil

    // В пространство.
    var pinned: [UUID] = []
    let pinModel = panelModel(theme: "vivid")
    pinModel.modifiers = { [] }
    pinModel.onPin = { id, _ in pinned.append(id) }
    _ = pinModel.handleKey(shiftRight)
    let target = pinModel.selectedItems.map(\.id)
    pinModel.pinSelected(to: ClipPanelFixture.spaces[0].id)
    check(pinned == target && !pinModel.isMultiSelected, "«В пространство» для всех выбранных")

    // Снимки: рамка на каждой, настоящий клик с Shift.
    for theme in ["graphite", "vivid"] {
        let shot = panelModel(theme: theme)
        shot.modifiers = { [] }
        shot.selected = 0
        _ = shot.handleKey(shiftRight)
        _ = shot.handleKey(shiftRight)
        let host = Stand.host(shot, width: 1440)
        await pause(0.4)
        let picture = snapshot(host, "\(theme == "graphite" ? "graphite" : "color")-multi", out: out)
        func ring(_ i: Int) -> ClipRGB { picture.rgb(cardOrigin(i).x - 3, cardOrigin(i).y + ClipCard.height / 2) }
        let backdrop = picture.rgb(cardOrigin(3).x - 3, cardOrigin(3).y + ClipCard.height / 2)
        for i in 0..<3 {
            check(abs(ring(i).r - backdrop.r) + abs(ring(i).g - backdrop.g) + abs(ring(i).b - backdrop.b) > 0.3, "\(theme): рамка на карточке \(i + 1)")
        }
        Stand.window.contentView = nil
    }
    let live = panelModel(theme: "vivid")
    var liveFlags: NSEvent.ModifierFlags = []
    live.modifiers = { liveFlags }
    var livePaste = 0
    live.onPaste = { _ in livePaste += 1 }
    _ = Stand.host(live, width: 1440)
    await pause(0.45)
    await windowClick(stripPoint(slot: 0))
    await pause(0.5)
    liveFlags = .shift
    await windowClick(stripPoint(slot: 2))
    await windowClick(stripPoint(slot: 2))
    check(live.selection.ids.count == 3 && livePaste == 0, "настоящий Shift+клик: диапазон, вставки нет")
    liveFlags = .command
    await windowClick(stripPoint(slot: 4))
    check(live.selection.ids.count == 4 && livePaste == 0, "настоящий ⌘+клик добавил")
    Stand.window.contentView = nil
}

/// Очередь вставки: настоящая запись в буфер стенда, настоящий опрос контроллера, подставной отправитель.
@MainActor func checkPasteMany() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-many-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ClipboardStore(directory: dir, key: SymmetricKey(size: .bits256), limit: 100)
    for text in ["четвёртая", "третья", "вторая", "первая"] {
        store.ingest(ClipSnapshot(types: [], text: text, sourceBundleID: "test.source.\(text)", sourceName: "Источник"))
    }
    let space = store.addSpace(name: "скрытая", colorID: "red", hidesContent: true)
    store.pin(store.items[1].id, to: space.id)
    let controller = ClipboardController.shared
    controller.observesSystem = false
    controller.attach(store)
    controller.start()
    defer { controller.stop(); controller.detachStore() }
    let board = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.pasteboard"))
    Kit.defaults.set(true, forKey: "Test.AXTrusted")
    defer { Kit.defaults.removeObject(forKey: "Test.AXTrusted") }
    let stand = LeaveStand()
    await stand.open()
    guard let panel = stand.panel else { return check(false, "окно стенда") }
    let before = store.items.map(\.id).sorted { $0.uuidString < $1.uuidString }
    let items = Array(store.items.prefix(3))
    var sent: [String] = []
    var windowGone = true
    let send = { @MainActor in
        if panel.isVisible { windowGone = false }
        sent.append(board.string(forType: .string) ?? "")
        // Опрос в самый неудобный момент: сразу после каждой записи.
        controller.poll()
    }
    let began = ProcessInfo.processInfo.systemUptime
    controller.pasteMany(items, host: stand.host, send: send)
    check(sent.isEmpty && panel.isVisible, "сначала панель уходит, ⌘V ещё нет")
    let finished = await waitUntil(5) { sent.count == 3 }
    let total = ProcessInfo.processInfo.systemUptime - began
    await pause(0.4)
    check(finished && sent == items.compactMap(\.text), "порядок вставки слева направо: \(sent)")
    check(windowGone, "к каждому ⌘V окна уже нет")
    check(total >= ClipPanelSpeed.normal.duration + ClipboardController.focusPause + 2 * ClipboardController.pasteGap - 0.05, "между записями пауза (\(total))")
    check(board.string(forType: .string) == items.last?.text, "в буфере последняя запись")
    check(store.items.map(\.id).sorted { $0.uuidString < $1.uuidString } == before, "новых записей в истории нет")
    check(items.allSatisfy { item in store.items.first { $0.id == item.id }?.sourceBundleID == item.sourceBundleID }, "опрос не принял записи за новые: источник прежний")
    check(sent.contains("третья") || sent.contains("вторая"), "скрытые вставляются как обычные")

    // Прерывание: панель открыли снова посреди очереди.
    sent = []
    await stand.open()
    controller.pasteMany(items, host: stand.host, send: send)
    _ = await waitUntil(3) { sent.count == 1 }
    await stand.open()
    await pause(ClipboardController.pasteGap * 3)
    check(sent.count == 1, "повторное открытие прервало очередь: ушла \(sent.count)")

    // Без разрешения: только первая и без ⌘V.
    stand.host.hide()
    _ = await waitUntil { stand.settledGone }
    Kit.defaults.set(false, forKey: "Test.AXTrusted")
    await stand.open()
    sent = []
    controller.pasteMany(items, host: stand.host, send: send)
    await pause(0.6)
    check(sent.isEmpty, "без разрешения ⌘V не уходит")
    check(board.string(forType: .string) == items[0].text, "в буфере первая запись")
    check(store.items.map(\.id).sorted { $0.uuidString < $1.uuidString } == before, "и ничего не потеряно")
    Kit.defaults.set(true, forKey: "Test.AXTrusted")

    // Предел.
    var many: [ClipItem] = []
    for i in 0..<25 {
        store.ingest(ClipSnapshot(types: [], text: "запись \(i)"))
        many.append(store.items[0])
    }
    controller.attach(store)
    check(ClipboardController.maxPasteMany == 20, "предел 20")
    var counted = 0
    await stand.open()
    ClipboardController.pasteSequence(stand.host, count: min(many.count, ClipboardController.maxPasteMany), write: { _ in counted += 1 }, send: {})
    _ = await waitUntil(8) { counted == 20 }
    await pause(ClipboardController.pasteGap * 2)
    check(counted == 20, "очередь не длиннее предела: \(counted)")
    stand.close()
}

/// Скорость появления и закрытия: значения, старые настройки, настоящий ход окна, ⌘V после ухода и при нуле.
@MainActor func checkPanelSpeed() async {
    let showKey = ClipboardPanelHost.showSpeedKey, hideKey = ClipboardPanelHost.hideSpeedKey
    check(ClipPanelSpeed.allCases.map(\.duration) == [0, 0.08, 0.16, 0.28], "четыре значения: 0, 0,08, 0,16, 0,28")
    check(ClipPanelSpeed.allCases.map(\.title) == ["Мгновенно", "Быстро", "Обычно", "Плавно"], "названия пунктов")
    check(ClipPanelSpeed.parse(nil) == .fast, "нет ключа (старые настройки): Быстро")
    check(ClipPanelSpeed.parse("warp") == .fast && ClipPanelSpeed.parse("") == .fast, "неизвестное значение: Быстро")
    Kit.defaults.removeObject(forKey: showKey)
    Kit.defaults.removeObject(forKey: hideKey)
    let fresh = ClipboardPanelModel()
    check(fresh.showSpeed == .fast && fresh.hideSpeed == .fast, "без ключей в меню галочка на «Быстро»")
    Kit.defaults.set(12345, forKey: showKey)
    check(ClipboardPanelModel().showSpeed == .fast, "значение другого типа: Быстро")
    fresh.setShowSpeed(.smooth)
    fresh.setHideSpeed(.instant)
    check(Kit.defaults.string(forKey: showKey) == "smooth" && Kit.defaults.string(forKey: hideKey) == "instant", "выбор сохранён")
    check(ClipboardPanelModel().showSpeed == .smooth && ClipboardPanelModel().hideSpeed == .instant, "и прочитан заново")

    /// Сколько окно реально шло: от вызова до конца. Показ и уход настоящие, окно стенда.
    func measure(show: ClipPanelSpeed, hide: ClipPanelSpeed) async -> (show: Double, hide: Double, showAtOnce: Bool, hideAtOnce: Bool, gone: Bool) {
        let stand = LeaveStand()
        Kit.defaults.set(show.rawValue, forKey: showKey)
        Kit.defaults.set(hide.rawValue, forKey: hideKey)
        await pause(0.05)
        stand.host.present(stand.model)
        let showAtOnce = stand.panel?.alphaValue == 1 && stand.panel?.frame == stand.frame
        let started = ProcessInfo.processInfo.systemUptime
        _ = await waitUntil(2) { stand.panel?.alphaValue == 1 && stand.panel?.frame == stand.frame }
        let shown = ProcessInfo.processInfo.systemUptime - started
        await pause(0.05)
        let left = ProcessInfo.processInfo.systemUptime
        stand.host.hide()
        let hideAtOnce = stand.panel?.isVisible == false
        let gone = await waitUntil(2) { stand.settledGone }
        let hidden = ProcessInfo.processInfo.systemUptime - left
        stand.close()
        return (shown, hidden, showAtOnce, hideAtOnce, gone)
    }
    for speed in ClipPanelSpeed.allCases {
        let run = await measure(show: speed, hide: speed)
        let d = speed.duration
        check(run.gone, "\(speed.title): панель ушла до конца")
        if d == 0 {
            check(run.showAtOnce, "\(speed.title): появление без анимации, сразу на месте")
            check(run.hideAtOnce, "\(speed.title): закрытие без анимации, окна уже нет")
        } else {
            check(!run.showAtOnce && !run.hideAtOnce, "\(speed.title): есть анимация")
            // Запас сверху на нагрузку и шаг опроса; снизу ровно столько, чтобы соседнее значение не прошло.
            check(run.show >= d * 0.7 && run.show <= d + 0.14, "\(speed.title): появление идёт \(d) с (замер \(run.show))")
            check(run.hide >= d * 0.7 && run.hide <= d + 0.14, "\(speed.title): закрытие идёт \(d) с (замер \(run.hide))")
        }
    }
    // Настройки независимы.
    let mixed = await measure(show: .instant, hide: .smooth)
    check(mixed.showAtOnce && !mixed.hideAtOnce && mixed.hide >= 0.2, "появление и закрытие настраиваются отдельно")
    // Уменьшение движения важнее.
    let reduced = LeaveStand()
    Kit.defaults.set(ClipPanelSpeed.smooth.rawValue, forKey: showKey)
    Kit.defaults.set(ClipPanelSpeed.smooth.rawValue, forKey: hideKey)
    reduced.host.reducesMotion = { true }
    reduced.host.present(reduced.model)
    check(reduced.panel?.alphaValue == 1, "«Уменьшить движение» важнее: появление сразу")
    reduced.host.hide()
    check(reduced.panel?.isVisible == false, "и закрытие сразу")
    reduced.close()
    // ⌘V после ухода и при нуле.
    let instant = LeaveStand()
    Kit.defaults.set(ClipPanelSpeed.instant.rawValue, forKey: showKey)
    Kit.defaults.set(ClipPanelSpeed.instant.rawValue, forKey: hideKey)
    await instant.open()
    var sends = 0
    var sentWhileVisible = false
    let began = ProcessInfo.processInfo.systemUptime
    var sentAt = 0.0
    ClipboardController.pasteAfterLeaving(instant.host) {
        sends += 1
        sentWhileVisible = instant.panel?.isVisible == true
        sentAt = ProcessInfo.processInfo.systemUptime - began
    }
    check(sends == 0 && instant.panel?.isVisible == false, "при нуле панель ушла сразу, ⌘V ещё нет")
    _ = await waitUntil { sends > 0 }
    check(sends == 1 && !sentWhileVisible && sentAt >= ClipboardController.focusPause - 0.01, "⌘V после ухода и паузы для фокуса (\(sentAt))")
    instant.close()
    Kit.defaults.removeObject(forKey: showKey)
    Kit.defaults.removeObject(forKey: hideKey)
}

/// Правила движения: короткие значения, выбор и смена вкладки не двигают ничего вокруг.
@MainActor func checkMotionRules(out: String) async {
    check((0.12...0.22).contains(ClipMotion.moveTime) && (0.12...0.22).contains(ClipMotion.fadeTime), "движения короткие: 0,12–0,22 с")
    let model = panelModel(theme: "vivid")
    let host = Stand.host(model, width: 1440)
    await pause(0.45)
    let rest = snapshot(host, out: out)
    func body(_ i: Int) -> CGRect { CGRect(x: cardOrigin(i).x + 8, y: cardOrigin(i).y + 8, width: ClipCard.width - 16, height: ClipCard.height - 16) }
    // Выбор: кадры сразу после клика, пока могла бы идти анимация.
    model.selected = 2
    var moved = 0
    for _ in 0..<6 {
        await pause(0.02)
        let shot = snapshot(host, out: out)
        moved += (0..<4).reduce(0) { $0 + changed(rest, shot, in: body($1)) }
    }
    check(moved == 0, "выбор меняет только рамку: внутри карточек ни одной другой точки (\(moved))")
    let ring = snapshot(host, out: out)
    check(changed(rest, ring, in: CGRect(x: cardOrigin(2).x - 4, y: cardOrigin(2).y, width: 3, height: ClipCard.height)) > 100, "и рамка на новой карточке")
    // Поиск раскрывается сразу: ни наложений в ряду, ни движения ленты.
    model.selected = 0
    await pause(0.05)
    let before = snapshot(host, out: out)
    model.openSearch()
    await pause(0.03)
    let opened = snapshot(host, out: out)
    await pause(0.4)
    let settled = snapshot(host, out: out)
    check(changed(opened, settled, in: CGRect(x: 0, y: 0, width: 1440, height: ClipPanelMetrics.panelHeight)) == 0, "поиск раскрылся сразу, без промежуточных кадров")
    check((0..<4).reduce(0) { $0 + changed(before, settled, in: body($1)) } == 0, "содержимое карточек при этом не шевельнулось")
    model.closeSearch()
    // Смена вкладки: затухание на месте. Ни один промежуточный кадр не показывает карточку не на своём месте: край ленты слева всегда на месте.
    await pause(0.1)
    model.selectTab(ClipPanelFixture.spaces[0].id)
    var edgeMoved = false
    for _ in 0..<6 {
        await pause(0.02)
        let shot = snapshot(host, out: out)
        if shot.count(in: CGRect(x: cardOrigin(0).x - 12, y: cardOrigin(0).y + 60, width: 6, height: 100), where: { min($0.r, $0.g, $0.b) > 0.5 }) > 0 { edgeMoved = true }
    }
    check(!edgeMoved, "смена вкладки: карточки не летят мимо своего места")
    await pause(ClipMotion.fadeTime + 0.3)
    Stand.window.contentView = nil
}

@MainActor func checkReorderLogic() {
    let panelFrame = CGRect(x: -1000, y: 300, width: 1440, height: 334)
    check(ClipboardPanelHost.pointInPanel(CGPoint(x: -900, y: 584), frame: panelFrame) == CGPoint(x: 100, y: 50), "курсор экрана в координатах панели, и на втором экране левее основного")
    check(ClipReorder.shift(0, from: 0, to: 2) == 2 && ClipReorder.shift(1, from: 0, to: 2) == -1 && ClipReorder.shift(2, from: 0, to: 2) == -1 && ClipReorder.shift(3, from: 0, to: 2) == 0, "сдвиги вправо")
    check(ClipReorder.shift(3, from: 3, to: 1) == -2 && ClipReorder.shift(1, from: 3, to: 1) == 1 && ClipReorder.shift(0, from: 3, to: 1) == 0, "сдвиги влево")
    let w = 100.0, gap = 10.0
    let others = [w, w, w]
    check(ClipReorder.slot(x: -500, others: others, dragged: w, gap: gap) == 0, "курсор левее ряда: первое место")
    check(ClipReorder.slot(x: 50, others: others, dragged: w, gap: gap) == 0, "над первым местом")
    check(ClipReorder.slot(x: 170, others: others, dragged: w, gap: gap) == 1, "над вторым местом")
    check(ClipReorder.slot(x: 5000, others: others, dragged: w, gap: gap) == 3, "правее ряда: последнее место")
    check(ClipReorder.slot(x: 10, others: [], dragged: w, gap: gap) == 0, "соседей нет")
    // Разная ширина: широкая рядом с узкой. Ответ зависит только от курсора, поэтому ряд не раскачивается: за один проход место только растёт.
    let wide = 300.0, narrow = [40.0, 40.0, 200.0]
    var last = 0
    var monotone = true
    for x in stride(from: 0.0, to: 800.0, by: 1.0) {
        let slot = ClipReorder.slot(x: x, others: narrow, dragged: wide, gap: gap)
        if slot < last { monotone = false }
        last = slot
    }
    check(monotone && last == 3, "широкая среди узких: место только растёт с курсором")
    let a = UUID(), b = UUID(), c = UUID()
    check(ClipReorder.moved([a, b, c], a, to: 2) == [b, c, a], "в конец")
    check(ClipReorder.moved([a, b, c], c, to: 0) == [c, a, b], "в начало")
    check(ClipReorder.moved([a, b], UUID(), to: 0) == [a, b], "чужой номер ничего не меняет")
}

/// Настоящие контроллер и хранилище во временной папке: то, что бросок делает до диска.
@MainActor final class OrderStand {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-order-\(UUID().uuidString)")
    let key = SymmetricKey(size: .bits256)
    let store: ClipboardStore
    let model: ClipboardPanelModel
    let boards = (0..<2).map { _ in NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)")) }
    var pasted: [UUID] = []

    init(theme: String = "vivid") {
        Kit.defaults.set(theme, forKey: DSTheme.storageKey)
        store = ClipboardStore(directory: dir, key: key, limit: 100)
        ClipboardController.shared.attach(store)
        model = ClipboardPanelHost.shared.makeModel(ClipboardController.shared)
        model.refreshTheme()
        model.imageLoader = ClipPanelFixture.image
        model.onPaste = { [unowned self] in pasted.append($0.id) }
        model.modifiers = { [] }
    }

    func sync() {
        model.allItems = ClipboardController.shared.items
        model.spaces = ClipboardController.shared.spaces
    }

    func drag(_ type: UTType, _ id: UUID) -> FakeDrag {
        let board = boards[type == ClipDrag.spaceType ? 1 : 0]
        let item = NSPasteboardItem()
        item.setData(ClipDrag.data(for: id), forType: NSPasteboard.PasteboardType(type.identifier))
        board.clearContents(); board.writeObjects([item])
        return FakeDrag(board, Stand.window)
    }

    func foreign() -> FakeDrag {
        let board = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.clipdrag.\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        item.setString("посторонний текст", forType: .string)
        board.clearContents(); board.writeObjects([item])
        return FakeDrag(board, Stand.window)
    }

    func close() {
        Stand.window.contentView = nil
        boards.forEach { $0.releaseGlobally() }
        ClipboardController.shared.detachStore()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Точка окна над местом в ленте: от левого нижнего угла окна, как у настоящего сеанса.
func stripPoint(slot: Int) -> NSPoint {
    let o = cardOrigin(slot)
    return NSPoint(x: o.x + ClipCard.width / 2, y: ClipPanelMetrics.panelHeight - o.y - ClipCard.height / 2)
}

@MainActor func windowClick(_ p: NSPoint, count: Int = 1) async {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: Stand.window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
        Stand.window.sendEvent(event!)
    }
    await pause(0.06)
}

/// Кого выберет сам AppKit под этой точкой. Настоящего сеанса на стенде нет, но выбор цели идёт через этот метод окна:
/// подставной сеанс, отправленный прямо в нужный вид, этого не показывал. Типы: приёмники SwiftUI регистрируют только `public.data`.
@MainActor func appKitTarget(_ host: NSView, _ point: NSPoint) -> NSView? {
    let selector = NSSelectorFromString("_hitTest:dragTypes:")
    guard host.responds(to: selector) else { return nil }
    typealias Hit = @convention(c) (AnyObject, Selector, UnsafePointer<NSPoint>, AnyObject) -> AnyObject?
    var at = point
    return unsafeBitCast(host.method(for: selector), to: Hit.self)(host, selector, &at, NSSet(array: ["public.data"])) as? NSView
}

@MainActor func checkRecordOrder(out: String) async {
    let stand = OrderStand()
    defer { stand.close() }
    let store = stand.store, model = stand.model
    let space = store.addSpace(name: "работа", colorID: "red")
    let other = store.addSpace(name: "другая", colorID: "blue")
    for name in ["один", "два", "три", "четыре", "вне категории"] { store.ingest(ClipSnapshot(types: [], text: name, sourceName: "Заметки")) }
    func id(_ text: String) -> UUID { store.items.first { $0.text == text }!.id }
    for name in ["четыре", "три", "два", "один"] { store.pin(id(name), to: space.id) }
    ClipboardController.shared.attach(store)
    stand.sync()
    func saved() -> [String] { store.items(in: space.id, query: "").compactMap(\.text) }
    func shown() -> [String] { model.visible.compactMap(\.text) }
    check(saved() == ["один", "два", "три", "четыре"], "в категории четыре записи, новая первая: \(saved())")

    // Курсор и кнопка подставные, всё остальное настоящее: таймер модели идёт сам.
    var cursor: CGPoint?
    var down = true
    model.pointer = { cursor }
    model.isMouseDown = { down }
    func over(_ slot: Int) -> CGPoint { CGPoint(x: cardOrigin(slot).x + ClipCard.width / 2, y: cardOrigin(slot).y + ClipCard.height / 2) }

    model.selectTab(space.id)
    let host = Stand.host(model, width: 1440)
    await pause(0.45)
    host.layoutSubtreeIfNeeded()
    check(model.stripFrames[ClipStripKey.strip] != nil && model.stripFrames[ClipStripKey.content] != nil, "панель знает, где лента")

    // Наведение: соседи расступаются, порядок и хранилище не меняются, выбор на той же записи.
    model.selected = 1
    let chosen = model.selectedItem?.id
    let carried = model.visible[0]
    let plain = snapshot(host, out: out)
    cursor = over(0)
    _ = model.dragProvider(for: carried)
    check(model.isTrackingDrag && model.draggedRecord == carried.id, "onDrag начал отслеживание: больше от источника ничего не нужно")
    cursor = over(2)
    await pause(0.1)
    check(model.recordSlot == 2, "таймер сам увидел курсор над третьим местом (\(String(describing: model.recordSlot)))")
    check(saved() == ["один", "два", "три", "четыре"] && shown() == saved(), "пока только наведение: порядок прежний")
    check(model.selectedItem?.id == chosen && model.selected == 1, "выбор на той же записи")
    cursor = over(1)
    let trackingEnd = Date().addingTimeInterval(0.1)
    while Date() < trackingEnd { RunLoop.main.run(mode: .eventTracking, before: trackingEnd) }
    check(model.recordSlot == 1, "таймер идёт и в режиме слежения за мышью")
    cursor = over(2)
    await pause(0.03)
    let moving = snapshot(host, "color-reorder-moving", out: out)
    await pause(0.6)
    let settled = snapshot(host, "color-reorder-hover", out: out)
    let wholeStrip = CGRect(x: 0, y: cardOrigin(0).y, width: 1200, height: ClipCard.height)
    let firstBody = CGRect(x: cardOrigin(0).x, y: cardOrigin(0).y + 60, width: ClipCard.width, height: 100)
    check(changed(plain, settled, in: firstBody) > 100, "на снимке соседи сдвинуты")
    check(ClipMotion.reduced || changed(moving, settled, in: wholeStrip) > 50, "через 0,03 с карточки ещё едут: движение, а не скачок")
    cursor = over(3)
    await pause(0.1)
    check(model.recordSlot == 3, "дальше: ещё сосед расступился")
    check(model.recordShift(at: 0, draggedAt: 0) == 3 * (ClipCard.width + ClipPanelMetrics.cardGap) && model.recordShift(at: 2, draggedAt: 0) == -(ClipCard.width + ClipPanelMetrics.cardGap), "сдвиги: сама на три места, сосед на одно")

    // Ушёл с ленты: на ряд категорий, в другую программу.
    cursor = CGPoint(x: 400, y: 5)
    await pause(0.1)
    check(model.recordSlot == nil, "ушёл с ленты: соседи вернулись")
    check(model.isTrackingDrag, "но перенос ещё идёт")
    cursor = CGPoint(x: -500, y: -500)
    down = false
    await pause(0.1)
    check(!model.isTrackingDrag && model.draggedRecord == nil, "кнопку отпустили снаружи: перенос окончен")
    check(saved() == ["один", "два", "три", "четыре"], "вынос наружу порядок не меняет")
    check(model.selectedItem?.id == chosen, "и выбор на той же записи")

    // Настоящий бросок: кнопку отпустили над лентой, сам приёмник мог и не отозваться.
    down = true
    cursor = over(0)
    _ = model.dragProvider(for: carried)
    cursor = over(2)
    await pause(0.1)
    down = false
    await pause(0.1)
    check(saved() == ["два", "три", "один", "четыре"], "отпустили над лентой: порядок сохранён: \(saved())")
    check(ClipboardStore(directory: stand.dir, key: stand.key, limit: 100).items(in: space.id, query: "").compactMap(\.text) == saved(), "порядок прочитан с диска")
    check(shown() == saved() && model.recordSlot == nil, "панель показывает новый порядок")
    check(model.selectedItem?.id == chosen, "после броска выбор на той же записи: \(model.selectedItem?.text ?? "")")
    await pause(0.5)
    let landed = snapshot(host, "color-reorder-landed", out: out)
    check(changed(plain, landed, in: firstBody) > 100, "на снимке новый порядок")

    // Цель броска: что выберет сам AppKit, и что она ответит на настоящую цепочку вызовов.
    host.layoutSubtreeIfNeeded()
    let dropPoint = NSPoint(x: over(1).x, y: ClipPanelMetrics.panelHeight - over(1).y)
    let picked = appKitTarget(host, dropPoint)
    check(picked != nil && !isInTopBar(picked!), "AppKit под карточкой выбирает её приёмник")
    let gapPoint = NSPoint(x: cardOrigin(1).x - ClipPanelMetrics.cardGap / 2 + 1, y: dropPoint.y)
    check(appKitTarget(host, gapPoint) != nil, "и в зазоре между карточками есть приёмник")
    let tabRect = dropTargets(in: host)[0].convert(dropTargets(in: host)[0].bounds, to: nil)
    let tabPick = appKitTarget(host, NSPoint(x: tabRect.midX, y: tabRect.midY))
    check(tabPick.map(isInTopBar) == true, "AppKit над категорией выбирает её приёмник, а не ленту")
    if let picked {
        down = true
        cursor = over(1)
        let dragged = model.visible[2]
        _ = model.dragProvider(for: dragged)
        let drag = stand.drag(ClipDrag.recordType, dragged.id)
        drag.location = dropPoint
        check(picked.draggingEntered(drag) == .move, "над карточкой перенос, значка «+» нет")
        check(picked.draggingUpdated(drag) == .move && model.recordSlot == 1, "и при движении: место то же, что под курсором")
        check(picked.prepareForDragOperation(drag) && picked.performDragOperation(drag), "бросок на карточку принят: копия не поедет обратно")
        picked.concludeDragOperation(drag)
        check(!model.isTrackingDrag, "бросок закончил перенос сразу")
        down = false
        await pause(0.1)
        check(saved() == ["два", "один", "три", "четыре"], "приёмник и таймер не сделали перестановку дважды: \(saved())")
    }

    // Клик и вставка вторым кликом.
    await pause(0.5)
    let target = stripPoint(slot: 2)
    await windowClick(target)
    check(model.selected == 2 && stand.pasted.isEmpty, "настоящий клик выделил карточку и не вставил")
    await windowClick(target)
    check(stand.pasted.first == model.visible[2].id, "второй клик вставил запись с нового места")
    await pause(0.5)
    model.move(-1)
    check(model.selected == 1 && model.selectedItem?.id == model.visible[1].id, "стрелка идёт по новому порядку")

    // Вставка и повтор не меняют порядок.
    let order = saved()
    store.touch(id("один"))
    store.ingest(ClipSnapshot(types: [], text: "три"))
    check(saved() == order, "вставка и повтор не меняют порядок: \(saved())")

    // Бросок на другую категорию закрепляет туда, порядок ленты не трогает.
    stand.sync()
    await pause(0.2)
    down = true
    cursor = over(0)
    let tabs = dropTargets(in: host)
    check(tabs.count == 2, "у обеих категорий свой приёмник (\(tabs.count))")
    if tabs.count == 2 {
        let two = model.visible.first { $0.text == "два" }!
        _ = model.dragProvider(for: two)
        cursor = CGPoint(x: tabs[1].convert(tabs[1].bounds, to: nil).midX, y: 20)
        await pause(0.05)
        check(model.recordSlot == nil, "над вкладкой лента не расступается")
        let carriedAway = stand.drag(ClipDrag.recordType, two.id)
        check(tabs[1].draggingEntered(carriedAway) == .move, "над другой категорией перенос")
        check(tabs[1].performDragOperation(carriedAway), "бросок на другую категорию")
        tabs[1].concludeDragOperation(carriedAway)
        down = false
        await pause(0.3)
        check(store.items.first { $0.text == "два" }!.spaceID == other.id && !saved().contains("два"), "запись закрепилась в другой категории: \(saved())")
    }

    // Наружу отдаётся содержимое.
    down = false
    let outward = model.visible[0]
    let provider = model.dragProvider(for: outward)
    let text = await loaded(provider, "public.utf8-plain-text")
    await pause(0.1)
    check(text.flatMap { String(data: $0, encoding: .utf8) } == outward.text, "вынос наружу отдаёт содержимое")
    check(saved() == model.visible.compactMap(\.text), "и не меняет порядок")

    // Чужой тип, поиск, общая вкладка.
    host.layoutSubtreeIfNeeded()
    let before = saved()
    guard let strip = appKitTarget(host, dropPoint) else { return check(false, "приёмник карточки") }
    let foreign = stand.foreign()
    foreign.location = dropPoint
    check(strip.draggingEntered(foreign) == [], "посторонний текст лента не принимает")
    _ = strip.performDragOperation(foreign)
    strip.draggingExited(foreign)
    let spaceDrag = stand.drag(ClipDrag.spaceType, space.id)
    spaceDrag.location = dropPoint
    check(strip.draggingEntered(spaceDrag) == [], "категорию нельзя бросить на карточку")
    _ = strip.performDragOperation(spaceDrag)
    strip.draggingExited(spaceDrag)
    await pause(0.15)
    check(saved() == before && store.spaces.first?.id == space.id, "чужие типы ничего не поменяли")

    model.openSearch()
    await pause(0.1)
    down = true
    cursor = over(0)
    _ = model.dragProvider(for: model.visible[0])
    let inSearch = stand.drag(ClipDrag.recordType, model.visible[0].id)
    inSearch.location = dropPoint
    check(!model.canReorderRecords && !model.isTrackingDrag && strip.draggingEntered(inSearch) == [], "при поиске перестановки нет")
    cursor = over(1)
    await pause(0.05)
    check(model.recordSlot == nil, "и соседи не расступаются")
    model.query = "ч"
    check(model.visible.compactMap(\.text) == before.filter { $0.contains("ч") }, "выдача в порядке категории")
    _ = strip.performDragOperation(inSearch)
    down = false
    await pause(0.15)
    check(saved() == before, "бросок в поиске ничего не поменял")
    model.closeSearch()

    model.selectTab(nil)
    await pause(0.2)
    host.layoutSubtreeIfNeeded()
    down = true
    cursor = over(0)
    _ = model.dragProvider(for: model.visible[0])
    check(!model.isTrackingDrag, "в общей вкладке перестановка не начинается")
    if let any = appKitTarget(host, dropPoint) {
        let inHistory = stand.drag(ClipDrag.recordType, model.visible[0].id)
        inHistory.location = dropPoint
        check(any.draggingEntered(inHistory) == [], "приёмник в общей вкладке отвергает")
        _ = any.performDragOperation(inHistory)
    }
    down = false
    await pause(0.15)
    check(model.visible.map(\.id) == store.items.map(\.id), "общая вкладка по времени")
    check(saved() == before, "порядок категории не тронут")
}

// MARK: - Порядок категорий

@MainActor func checkSpaceOrder(out: String) async {
    let stand = OrderStand()
    defer { stand.close() }
    let store = stand.store, model = stand.model
    let a = store.addSpace(name: "работа", colorID: "red")
    _ = store.addSpace(name: "дом и очень длинное имя", colorID: "green")
    let c = store.addSpace(name: "код", colorID: "blue")
    ClipboardController.shared.attach(store)
    stand.sync()
    var cursor: CGPoint?
    var down = true
    model.pointer = { cursor }
    model.isMouseDown = { down }
    let host = Stand.host(model, width: 1440)
    await pause(0.45)
    host.layoutSubtreeIfNeeded()
    func names() -> [String] { store.spaces.map(\.name) }
    let tabs = dropTargets(in: host)
    guard tabs.count == 3 else { return check(false, "у каждой категории приёмник (\(tabs.count))") }
    func rect(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
    let y = rect(tabs[0]).midY
    let top = ClipPanelMetrics.panelHeight - y
    let rowMin = rect(tabs[0]).minX, rowMax = rect(tabs[2]).maxX
    for i in 0..<2 { check(abs(rect(tabs[i]).maxX - rect(tabs[i + 1]).minX) < 0.6, "приёмники соседних вкладок смыкаются") }
    check(appKitTarget(host, NSPoint(x: rect(tabs[1]).midX, y: y)) === tabs[1], "AppKit над вкладкой выбирает её приёмник")

    // «Буфер обмена» стоит левее ряда, приёмника на нём нет.
    let plain = snapshot(host, "color-spaces-plain", out: out)
    let bufferLabel = CGRect(x: rowMin - 110, y: top - 15, width: 60, height: 30)
    check(plain.count(in: bufferLabel) { min($0.r, $0.g, $0.b) > 0.5 } > 30, "«Буфер обмена» слева от ряда категорий")
    check(appKitTarget(host, NSPoint(x: bufferLabel.midX, y: y)) == nil, "на «Буфере обмена» приёмника нет: бросить левее него нельзя")

    let provider = ClipDrag.spaceProvider(for: a.id)
    check(provider.registeredTypeIdentifiers == [ClipDrag.spaceType.identifier], "наружу нести нечего: только свой тип (\(provider.registeredTypeIdentifiers))")
    check(ClipDrag.spaceType != ClipDrag.recordType && !ClipDrag.spaceType.conforms(to: ClipDrag.recordType) && !ClipDrag.recordType.conforms(to: ClipDrag.spaceType), "тип категории отдельный от типа записи")

    // Первая вкладка в конец: соседи расступаются, таймер идёт сам.
    cursor = CGPoint(x: rect(tabs[0]).midX, y: top)
    _ = model.spaceDragProvider(for: a.id)
    check(model.isTrackingDrag, "onDrag начал отслеживание")
    cursor = CGPoint(x: rowMax - 2, y: top)
    await pause(0.1)
    check(model.spaceSlot == 2, "над краем ряда: последнее место (\(String(describing: model.spaceSlot)))")
    check(names() == ["работа", "дом и очень длинное имя", "код"] && model.spaces.map(\.name) == names(), "на диск пока ничего")
    await pause(0.5)
    let right = snapshot(host, "color-spaces-hover-right", out: out)
    check(changed(plain, right, in: CGRect(x: rowMin, y: top - 15, width: rowMax - rowMin, height: 30)) > 100, "на снимке вкладки сдвинуты")
    check(model.spaceShift(c.id) < 0 && model.spaceShift(a.id) > 0, "соседи влево, несомая вправо")
    cursor = CGPoint(x: rect(tabs[0]).minX + 1, y: 200)
    await pause(0.1)
    check(model.spaceSlot == nil, "ушёл с ряда на ленту: вкладки вернулись")
    // Над «Буфером» тоже мимо, и отпускание там ничего не меняет.
    cursor = CGPoint(x: bufferLabel.midX, y: top)
    await pause(0.1)
    check(model.spaceSlot == nil, "над «Буфером обмена» места нет")
    down = false
    await pause(0.1)
    check(!model.isTrackingDrag && names() == ["работа", "дом и очень длинное имя", "код"], "бросок над «Буфером» порядок не меняет")

    // В начало ряда: первое место среди категорий, «Буфер обмена» на месте.
    down = true
    cursor = CGPoint(x: rowMax - 10, y: top)
    _ = model.spaceDragProvider(for: c.id)
    cursor = CGPoint(x: rowMin + 2, y: top)
    await pause(0.6)
    check(model.spaceSlot == 0, "в начало ряда: первое место (\(String(describing: model.spaceSlot)))")
    let left = snapshot(host, "color-spaces-hover", out: out)
    check(left.count(in: bufferLabel) { min($0.r, $0.g, $0.b) > 0.5 } > 30, "«Буфер обмена» остался на месте")
    // Место зависит только от курсора: вкладки сдвинуты, а ответ тот же.
    await pause(0.2)
    check(model.spaceSlot == 0, "ряд не раскачивается")
    // Цель броска: приёмник под курсором принимает, порядок один раз.
    let under = appKitTarget(host, NSPoint(x: rowMin + 2, y: y))
    check(under != nil, "под курсором есть приёмник")
    let drag = stand.drag(ClipDrag.spaceType, c.id)
    if let under {
        check(under.draggingEntered(drag) == .move, "над вкладкой перенос")
        check(under.draggingUpdated(drag) == .move, "и при движении")
        check(under.prepareForDragOperation(drag) && under.performDragOperation(drag), "бросок выполнен")
        under.concludeDragOperation(drag)
    }
    down = false
    await pause(0.3)
    check(names() == ["код", "работа", "дом и очень длинное имя"], "порядок сохранён: \(names())")
    check(ClipboardStore(directory: stand.dir, key: stand.key, limit: 100).spaces.map(\.name) == names(), "порядок прочитан с диска")
    check(model.spaces.map(\.name) == names() && model.spaceSlot == nil, "панель показывает новый порядок")
    // Без отзыва приёмника: кнопку отпустили над рядом.
    await pause(0.3)
    host.layoutSubtreeIfNeeded()
    down = true
    cursor = CGPoint(x: rowMin + 2, y: top)
    _ = model.spaceDragProvider(for: c.id)
    cursor = CGPoint(x: rowMax + 30, y: top)
    await pause(0.1)
    down = false
    await pause(0.2)
    check(names() == ["работа", "дом и очень длинное имя", "код"], "отпустили правее ряда: последнее место: \(names())")

    // Общее с кнопками ↑↓.
    ClipboardController.shared.moveSpace(c.id, by: -1)
    check(names() == ["работа", "код", "дом и очень длинное имя"], "кнопка ↑ двигает тот же порядок")
    store.moveSpace(c.id, to: -5)
    check(names().first == "код", "место левее начала: первая категория")
    store.moveSpace(c.id, to: 99)
    check(names().last == "код", "место за краем: последняя")
    stand.sync()
    await pause(0.3)
    host.layoutSubtreeIfNeeded()

    // Посторонний текст вкладка не принимает, запись по-прежнему закрепляется.
    let tabsNow = dropTargets(in: host)
    let order = names()
    let foreign = stand.foreign()
    check(tabsNow[0].draggingEntered(foreign) == [], "посторонний текст вкладка не принимает")
    tabsNow[0].draggingExited(foreign)
    store.ingest(ClipSnapshot(types: [], text: "запись"))
    ClipboardController.shared.attach(store)
    stand.sync()
    await pause(0.3)
    host.layoutSubtreeIfNeeded()
    let carry = stand.drag(ClipDrag.recordType, store.items[0].id)
    let onTab = dropTargets(in: host)[0]
    check(onTab.draggingEntered(carry) == .move && onTab.performDragOperation(carry), "запись на категорию бросается как раньше")
    onTab.concludeDragOperation(carry)
    await pause(0.3)
    check(store.items[0].spaceID == store.spaces[0].id && names() == order, "запись закрепилась, порядок категорий не тронут")

    // Настоящий клик по вкладке: без `Button` он всё равно выбирает её.
    await windowClick(NSPoint(x: rect(dropTargets(in: host)[0]).minX + 20, y: y))
    check(model.tab == store.spaces[0].id, "клик по категории открыл её вкладку")
    model.selectTab(nil)
    await pause(0.1)

    // Настоящие клики в поле новой категории и + в ряду.
    // При поиске, где категории сжаты до точек, перестановки нет.
    model.openSearch()
    await pause(0.4)
    host.layoutSubtreeIfNeeded()
    let dots = dropTargets(in: host)
    check(dots.count == 3, "точки принимают записи (\(dots.count))")
    if let dot = dots.first {
        down = true
        cursor = CGPoint(x: rect(dot).midX, y: top)
        _ = model.spaceDragProvider(for: a.id)
        check(!model.canReorderSpaces && !model.isTrackingDrag, "при поиске перестановка категорий не начинается")
        let inSearch = stand.drag(ClipDrag.spaceType, a.id)
        check(dot.draggingEntered(inSearch) == [], "и приёмник отвергает")
        _ = dot.performDragOperation(inSearch)
        down = false
        await pause(0.15)
        check(names() == order, "бросок при поиске ничего не поменял")
        await windowClick(NSPoint(x: rect(dot).midX, y: rect(dot).midY))
        check(model.tab == store.spaces[0].id, "клик по точке категории работает")
    }
    model.closeSearch()
    model.selectTab(nil)
    await pause(0.3)

    // Кнопка +: настоящее поле в ряду, снимки, Esc.
    host.layoutSubtreeIfNeeded()
    model.beginCreate()
    await pause(0.4)
    check(Stand.window.firstResponder is NSTextView, "поле новой категории взяло клавиатуру")
    let field = Stand.window.firstResponder as? NSTextView
    check(field?.selectedRange() == NSRange(location: 0, length: 12), "«Без названия» выделено: \(String(describing: field?.selectedRange()))")
    _ = snapshot(host, "color-new-space", out: out)
    field?.insertText("Пароли", replacementRange: field?.selectedRange() ?? NSRange())
    check(model.spaceNameEdit?.text == "Пароли" && !model.searchOpen && model.query.isEmpty, "буквы идут в поле, поиск не открылся")
    model.commitInlineEdit()
    await pause(0.2)
    check(model.tab == store.spaces.last?.id && store.spaces.last?.name == "Пароли", "после ввода открыта вкладка новой категории")
    check(Stand.window.firstResponder is NSTextView, "клавиатура вернулась в поле поиска")
    model.selectTab(nil)
    model.beginCreate()
    await pause(0.2)
    let count = store.spaces.count
    check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && store.spaces.count == count - 1, "Esc убрал новую категорию из настоящего ряда")
    await pause(0.2)
    Kit.defaults.set("graphite", forKey: DSTheme.storageKey)
    model.refreshTheme()
    model.beginCreate()
    await pause(0.4)
    _ = snapshot(host, "graphite-new-space", out: out)
    model.cancelInlineEdit()
    await pause(0.1)
    Kit.defaults.set("vivid", forKey: DSTheme.storageKey)
    model.refreshTheme()
}

// MARK: - Название

/// Заголовок карточки на снимке: левый край текста, от левого нижнего угла окна.
func titlePoint(card: Int) -> NSPoint {
    let o = cardOrigin(card)
    return NSPoint(x: o.x + ClipboardPreview.textInset + 12, y: ClipPanelMetrics.panelHeight - o.y - 14)
}

@MainActor func checkTitle(out: String) async {
    // Клавиши и логика клика.
    do {
        let model = panelModel(theme: "vivid")
        var pasted = 0, closed = 0
        var titles: [UUID: String?] = [:]
        model.onPaste = { _ in pasted += 1 }
        model.onClose = { closed += 1 }
        model.onSetTitle = { id, title in titles[id] = title }
        let list = model.visible
        let t: TimeInterval = 1000
        model.clickTitle(list[2], time: t)
        check(model.selected == 2 && model.titleEdit == nil && pasted == 0, "клик по заголовку невыбранной просто выбирает её")
        model.clickTitle(list[2], time: t + 0.1)
        check(model.titleEdit?.id == list[2].id && pasted == 0, "второй клик в заголовок выбранной: правка, а не вставка")
        model.cancelTitleEdit()
        model.click(list[2], at: 2, time: t + 0.2)
        check(pasted == 0, "после заголовка отсчёт сброшен: следующий клик по карточке не вставляет")
        model.clickTitle(list[2], time: t + 0.25)
        check(pasted == 0 && model.titleEdit != nil, "клик по телу и сразу по заголовку не вставил")
        model.cancelTitleEdit()

        // Правка забирает клавиши.
        model.beginTitleEdit(list[2])
        check(!model.handleKey(ClipPanelKey(code: 0, text: "п")) && !model.searchOpen && model.query.isEmpty, "буква идёт в поле названия, поиск не открылся")
        check(!model.handleKey(ClipPanelKey(code: right, text: "\u{F703}")) && model.selected == 2, "стрелка двигает курсор в поле, а не выбор")
        check(!model.handleKey(ClipPanelKey(code: 18, command: true, text: "1")) && pasted == 0, "⌘1 не вставляет")
        check(!model.handleKey(ClipPanelKey(code: del, command: true, text: "\u{7f}")), "⌘⌫ не удаляет запись")
        check(model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) && model.titleEdit == nil && closed == 0, "Esc отменил правку, а не закрыл панель")
        check(titles.isEmpty, "отмена ничего не сохранила")
        check(!model.handleKey(ClipPanelKey(code: 0, text: "п")) && model.searchOpen, "после правки буква снова открывает поиск")
        model.closeSearch()
        model.beginTitleEdit(list[2])
        model.titleEdit?.text = "  Имя \n записи "
        check(model.handleKey(ClipPanelKey(code: enter, text: "\r")) && model.titleEdit == nil, "Enter сохранил и закрыл поле")
        check(titles[list[2].id] == .some("Имя записи") && pasted == 0, "сохранено очищенное имя, вставки нет")
        titles = [:]
        model.allItems[model.allItems.firstIndex { $0.id == list[2].id }!].title = "Имя"
        model.beginTitleEdit(model.visible[2])
        check(model.titleEdit?.text == "Имя", "в поле текущее название")
        model.titleEdit?.text = "   "
        model.commitTitleEdit()
        check(titles[list[2].id] == .some(nil), "пустое имя убирает название")
        titles = [:]
        model.beginTitleEdit(model.visible[2])
        model.commitTitleEdit()
        // Название в модели подставное и после уборки осталось прежним: то же имя второй раз не пишется.
        check(titles.isEmpty, "имя не менялось: записи нет")
    }

    // Поиск и перенос: через настоящее хранилище.
    do {
        let stand = OrderStand()
        defer { stand.close() }
        stand.store.ingest(ClipSnapshot(types: [], text: "настоящий текст записи", sourceName: "Заметки"))
        ClipboardController.shared.attach(stand.store)
        stand.sync()
        let model = stand.model
        model.beginTitleEdit(model.visible[0])
        model.titleEdit?.text = "Важная"
        model.commitTitleEdit()
        check(stand.store.items[0].title == "Важная" && model.allItems[0].title == "Важная", "название дошло до хранилища и панели")
        model.query = "важн"
        check(model.visible.count == 1, "поиск находит по названию")
        model.closeSearch()
        let provider = model.dragProvider(for: model.visible[0])
        let text = await loaded(provider, "public.utf8-plain-text")
        check(text.flatMap { String(data: $0, encoding: .utf8) } == "настоящий текст записи", "перенос наружу отдаёт содержимое, а не название")
        check(!provider.registeredTypeIdentifiers.contains("public.url"), "название не становится адресом")
    }

    // Настоящие клики: заголовок выбранной и невыбранной. Снимки в обеих темах.
    for theme in ["graphite", "vivid"] {
        let suffix = theme == "graphite" ? "graphite" : "color"
        let now = Date()
        var items = ClipPanelFixture.items(now: now)
        items[0].title = "Приглашение в команду"
        items[1].title = "Очень длинное название карточки, которое обязательно обрежется"
        let model = panelModel(theme: theme, items: items)
        var pasted = 0
        model.onPaste = { _ in pasted += 1 }
        var saved: String?
        model.onSetTitle = { [weak model] id, title in
            saved = title
            if let index = model?.allItems.firstIndex(where: { $0.id == id }) { model?.allItems[index].title = title }
        }
        let host = Stand.host(model, width: 1440)
        await pause(0.45)
        host.layoutSubtreeIfNeeded()
        _ = snapshot(host, "\(suffix)-title", out: out)
        if theme == "vivid" {
            await windowClick(titlePoint(card: 2))
            check(model.selected == 2 && model.titleEdit == nil && pasted == 0, "настоящий клик по заголовку невыбранной выбрал её")
            await windowClick(titlePoint(card: 2))
            check(model.titleEdit?.id == items[2].id && pasted == 0, "настоящий клик по заголовку выбранной открыл правку и не вставил")
            await pause(0.2)
            check(Stand.window.firstResponder is NSTextView, "поле названия взяло клавиатуру")
            let editor = Stand.window.firstResponder as? NSTextView
            editor?.insertText("Имя", replacementRange: editor?.selectedRange() ?? NSRange())
            check(model.titleEdit?.text == "Имя", "буквы идут в поле названия: «\(model.titleEdit?.text ?? "")»")
            check(!model.searchOpen && model.query.isEmpty, "поиск не открылся")
            model.commitTitleEdit()
            await pause(0.15)
            check(saved == "Имя" && pasted == 0, "сохранено без вставки")
            check(Stand.window.firstResponder is NSTextView, "клавиатура вернулась в поле поиска")

            // Уже с названием: текст в поле выделен целиком.
            await windowClick(titlePoint(card: 2))
            await pause(0.25)
            let field = Stand.window.firstResponder as? NSTextView
            check(field?.selectedRange() == NSRange(location: 0, length: 3), "при правке текст выделен: \(String(describing: field?.selectedRange()))")
            model.cancelTitleEdit()
            await pause(0.1)
            await windowClick(titlePoint(card: 0))
            await pause(0.1)
            // Обычный двойной клик ниже заголовка у той же карточки работает как раньше.
            let body = NSPoint(x: cardOrigin(0).x + 100, y: ClipPanelMetrics.panelHeight - cardOrigin(0).y - 120)
            await pause(0.5)
            await windowClick(body)
            await windowClick(body)
            check(pasted == 1 && model.titleEdit == nil, "двойной клик по телу карточки вставляет как раньше")
        }
        model.selected = 0
        model.beginTitleEdit(model.visible[0])
        await pause(0.25)
        _ = snapshot(host, "\(suffix)-title-edit", out: out)
        model.cancelTitleEdit()
        Stand.window.contentView = nil
    }

    // Клик мимо и закрытие: на настоящем мониторе, события приходят через приложение.
    let stand = LeaveStand()
    stand.model.onRenameSpace = { [weak model = stand.model] id, name in
        if let index = model?.spaces.firstIndex(where: { $0.id == id }) { model?.spaces[index].name = name }
    }
    stand.model.onSetTitle = { [weak model = stand.model] id, title in
        if let index = model?.allItems.firstIndex(where: { $0.id == id }) { model?.allItems[index].title = title }
    }
    await stand.open()
    func panelClick(_ p: NSPoint) async {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: stand.panel!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Отпускание заранее в очереди своего процесса: поле ввода при нажатии само ждёт его во вложенном цикле.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        NSApp.sendEvent(event(.leftMouseDown))
        await pause(0.08)
    }
    let first = stand.model.visible[0]
    stand.model.beginTitleEdit(first)
    await pause(0.25)
    check(stand.panel?.firstResponder is NSTextView, "на стенде панели поле взяло клавиатуру")
    stand.model.titleEdit?.text = "В самом поле"
    await panelClick(titlePoint(card: 0))
    check(stand.model.titleEdit != nil, "клик в самом поле правку не закрывает")
    stand.model.titleEdit?.text = "Клик мимо"
    await panelClick(NSPoint(x: 1400, y: 20))
    check(stand.model.titleEdit == nil && stand.model.allItems.first { $0.id == first.id }?.title == "Клик мимо", "клик мимо сохранил правку")
    stand.model.beginTitleEdit(first)
    stand.model.titleEdit?.text = "Закрытие"
    stand.host.hide()
    check(stand.model.titleEdit == nil && stand.model.allItems.first { $0.id == first.id }?.title == "Закрытие", "закрытие панели сохранило правку")
    _ = await waitUntil { stand.settledGone }
    await stand.open()
    // Имя категории: клик мимо сохраняет, как и название.
    stand.model.beginRename(stand.model.spaces[0])
    await pause(0.25)
    stand.model.spaceNameEdit?.text = "Новое имя"
    await panelClick(NSPoint(x: 1400, y: 20))
    check(stand.model.spaceNameEdit == nil && stand.model.spaces[0].name == "Новое имя", "клик мимо сохранил имя категории")
    stand.close()
}

// MARK: - Скрытие

/// Снимок одной карточки на подложке: точно то, что рисует панель или копия при переносе.
@MainActor func cardShot(_ item: ClipItem, spaces: [ClipSpace], model: ClipboardPanelModel, concealed: Bool, preview: Bool, now: Date) async -> (Shot, [String]) {
    let root = ZStack(alignment: .topLeading) {
        Color(red: 0.13, green: 0.14, blue: 0.16)
        ClipCard(item: item, number: 1, selected: false, searching: false, theme: model.theme, spaces: spaces, now: now,
                 model: model, concealed: concealed, isDragPreview: preview)
    }
    .frame(width: ClipCard.width, height: ClipCard.height)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: ClipCard.width, height: ClipCard.height)
    Stand.window.setContentSize(host.frame.size)
    Stand.window.contentView = host
    await pause(0.25)
    let shot = snapshot(host, out: "")
    Stand.window.contentView = nil
    return (shot, viewTexts(ClipCard(item: item, number: 1, selected: false, searching: false, theme: model.theme, spaces: spaces, now: now,
                                     model: model, concealed: concealed, isDragPreview: preview)))
}

/// Весь текст дерева вида: подписи, заголовки и `.help` хранятся в нём значениями. Сверка на настоящем `body`, отражением.
/// Только строки `Text`: копия при переносе лежит в дереве значением вместе со своей записью, но показывает её только свой `body`, а его отдельно проверяет `preview: true`.
@MainActor func viewTexts(_ card: ClipCard) -> [String] {
    var out = ""
    dump(card.body, to: &out, maxDepth: 80)
    return out.split(separator: "\n").map(String.init).filter { $0.contains("verbatim:") }
}

@MainActor func identicalPixels(_ a: Shot, _ b: Shot) -> Bool {
    guard a.bitmap.pixelsWide == b.bitmap.pixelsWide, a.bitmap.pixelsHigh == b.bitmap.pixelsHigh,
          let p = a.bitmap.bitmapData, let q = b.bitmap.bitmapData, a.bitmap.bytesPerRow == b.bitmap.bytesPerRow else { return false }
    return memcmp(p, q, a.bitmap.bytesPerRow * a.bitmap.pixelsHigh) == 0
}

@MainActor func checkConcealment(out: String) async {
    let now = Date()
    let hidden = ClipSpace(id: UUID(), name: "пароли", colorID: "red", hidesContent: true)
    let open = ClipSpace(id: UUID(), name: "открытая", colorID: "blue")
    let spaces = [hidden, open]
    func entry(_ kind: ClipKind, _ text: String?, paths: [String]? = nil, size: (Int, Int)? = nil, in space: UUID? = hidden.id) -> ClipItem {
        ClipPanelFixture.entry(kind, text, source: "com.apple.Notes", ago: 240, now: now, paths: paths, size: size, space: space)
    }
    // Пары одного вида с разным содержимым: у скрытых карточек пиксели обязаны совпасть до байта, что бы ни лежало внутри.
    let pairs: [(String, ClipItem, ClipItem, String)] = [
        ("текст", entry(.text, "пароль-секрет-1"), entry(.text, "другое содержимое\nдругой длины и из нескольких строк\nещё строка"), "пароль-секрет-1"),
        ("ссылка", entry(.link, "https://secret.example.com/a"), entry(.link, "https://other.example.org/bbb"), "secret.example.com"),
        ("картинка", entry(.image, nil, size: (1600, 900)), entry(.image, nil, size: (10, 20)), "1600"),
        ("файлы", entry(.file, nil, paths: ["/tmp/секретный отчёт.pdf"]), entry(.file, nil, paths: ["/tmp/другой.txt", "/tmp/третий.txt"]), "секретный отчёт"),
    ]
    let model = panelModel(theme: "vivid")
    var imageCalls = 0
    model.imageLoader = { imageCalls += 1; return ClipPanelFixture.image($0) }
    for (name, a, b, secret) in pairs {
        for preview in [false, true] {
            let what = preview ? "копия при переносе" : "карточка"
            let (shotA, textsA) = await cardShot(a, spaces: spaces, model: model, concealed: true, preview: preview, now: now)
            let (shotB, _) = await cardShot(b, spaces: spaces, model: model, concealed: true, preview: preview, now: now)
            check(identicalPixels(shotA, shotB), "\(name), \(what): пиксели не зависят от содержимого")
            check(!textsA.contains { $0.contains(secret) }, "\(name), \(what): содержимого нет в тексте вида")
            check(textsA.contains { $0.contains(ClipConcealment.mask) }, "\(name), \(what): вместо него точки (\(textsA))")
            check(!textsA.contains { $0.contains("символ") || $0.contains("×") || $0.contains("файл ") }, "\(name), \(what): подписи о размере нет")
            // Та же пара открытая расходится: сверка выше чего-то стоит.
            let (openA, openTexts) = await cardShot(a, spaces: spaces, model: model, concealed: false, preview: preview, now: now)
            let (openB, _) = await cardShot(b, spaces: spaces, model: model, concealed: false, preview: preview, now: now)
            check(!identicalPixels(openA, openB), "\(name), \(what): открытые карточки разные, сверка не пустая")
            if a.kind == .text || a.kind == .link { check(openTexts.contains { $0.contains(secret) }, "\(name), \(what): у открытой текст виден (текстовая сверка не пустая)") }
        }
    }
    check(imageCalls > 0, "открытая картинка загружается")
    imageCalls = 0
    _ = await cardShot(pairs[2].1, spaces: spaces, model: model, concealed: true, preview: false, now: now)
    check(imageCalls == 0, "у скрытой картинка даже не расшифровывается")

    // Копия при переносе скрыта и у записи, открытой на время: настоящий путь, тело `onDrag` собирается из того же условия.
    check(ClipConcealment.isHidden(pairs[0].1, in: spaces), "запись категории со скрытием скрыта")
    check(!ClipConcealment.isHidden(entry(.text, "x", in: open.id), in: spaces), "у обычной категории нет")
    check(!ClipConcealment.isHidden(entry(.text, "x", in: nil), in: spaces), "у записи без категории нет")

    // Название и точки, в общей вкладке и во вкладке категории: снимки и обе темы.
    for theme in ["graphite", "vivid"] {
        let suffix = theme == "graphite" ? "graphite" : "color"
        var titled = pairs[0].1
        titled.title = "Пароль от почты"
        let items = [titled, pairs[0].2, pairs[1].1, pairs[2].1, pairs[3].1, entry(.text, "обычная запись", in: nil)]
        let panel = panelModel(theme: theme, items: items)
        panel.spaces = spaces
        _ = await Stand.render(panel, "\(suffix)-hidden-history", out: out)
        panel.selectTab(hidden.id)
        let tab = await Stand.render(panel, "\(suffix)-hidden", out: out)
        // Шапка с названием своя, тело без текста: кроме точек по центру ничего яркого.
        let o = cardOrigin(1)
        let body = CGRect(x: o.x, y: o.y + ClipCard.headerHeight, width: ClipCard.width, height: 30)
        check(tab.count(in: body) { min($0.r, $0.g, $0.b) > 0.5 } == 0, "\(suffix): там, где начинался текст, пусто")

        let editors = panelModel(theme: theme)
        editors.spaces = spaces
        editors.beginEdit(hidden)
        check(editors.editor?.hidesContent == true, "окошко правки показывает настройку категории")
        _ = await Stand.render(editors, "\(suffix)-editor-hide", out: out)
        editors.beginEdit(open)
        check(editors.editor?.hidesContent == false, "по умолчанию без скрытия")
        _ = await Stand.render(editors, "\(suffix)-editor-hide-off", out: out)
    }

    // В общей вкладке и в категории одна и та же карточка, сверка настоящей панели: другое содержимое даёт тот же кадр.
    for tabID in [nil, hidden.id] as [UUID?] {
        var shots: [Shot] = []
        for content in ["первый-секрет", "совсем другой текст другой длины"] {
            let item = ClipPanelFixture.entry(.text, content, source: "com.apple.Notes", ago: 240, now: now, space: hidden.id)
            let panel = panelModel(theme: "vivid", items: [item])
            panel.spaces = spaces
            panel.selectTab(tabID)
            shots.append(await Stand.render(panel, "color-hidden-compare", out: out))
        }
        let rect = CGRect(x: cardOrigin(0).x, y: cardOrigin(0).y, width: ClipCard.width, height: ClipCard.height)
        check(changed(shots[0], shots[1], in: rect) == 0, "\(tabID == nil ? "общая вкладка" : "вкладка категории"): настоящая панель не показывает содержимое")
    }

    // Весь путь на настоящем контроллере и хранилище: настройка, поиск, открытие, закрытие, вставка, перенос.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-conceal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ClipboardStore(directory: dir, key: SymmetricKey(size: .bits256), limit: 100)
    let controller = ClipboardController.shared
    controller.attach(store)
    store.ingest(ClipSnapshot(types: [], text: "пароль-qwerty", sourceBundleID: "com.apple.Notes", sourceName: "Заметки"))
    let id = store.items[0].id
    controller.attach(store)
    let stand = LeaveStand(wired: true)
    defer { stand.close(); controller.detachStore() }
    let wired = stand.model
    wired.allItems = controller.items
    await stand.open()
    wired.allItems = controller.items
    wired.spaces = controller.spaces
    wired.beginCreate()
    wired.spaceNameEdit?.text = "пароли"
    wired.commitInlineEdit()
    let spaceID = store.spaces[0].id
    check(store.spaces[0].hidesContent == nil, "создана без скрытия")
    wired.selectTab(nil)
    wired.pin(id, to: spaceID)
    check(!wired.isConcealed(wired.allItems[0]), "пока без скрытия карточка открыта")
    wired.query = "qwerty"
    check(wired.visible.count == 1, "поиск находит по содержимому, пока скрытия нет")
    wired.closeSearch()
    wired.beginEdit(wired.spaces[0])
    wired.editor?.hidesContent = true
    wired.commitEditor()
    check(store.spaces[0].hidesContent == true && wired.spaces[0].hidesContent == true, "настройка из окошка дошла до хранилища и панели")
    check(wired.isConcealed(wired.allItems[0]), "поставили скрытие на категорию с записями: действует сразу")
    wired.query = "qwerty"
    check(wired.visible.isEmpty, "скрытая запись не находится поиском по содержимому")
    wired.query = "заметки"
    check(wired.visible.isEmpty, "и по программе, откуда скопирована")
    wired.closeSearch()
    wired.beginEdit(wired.spaces[0])
    wired.editor?.hidesContent = false
    wired.commitEditor()
    check(!wired.isConcealed(wired.allItems[0]), "сняли: сразу видно")
    wired.beginEdit(wired.spaces[0])
    wired.editor?.hidesContent = true
    wired.commitEditor()

    wired.reveal(id)
    check(!wired.isConcealed(wired.allItems[0]) && ClipConcealment.isHidden(wired.allItems[0], in: wired.spaces), "«Показать» открывает только на время")
    wired.query = "qwerty"
    check(wired.visible.isEmpty, "открытая на время запись поиском по содержимому всё равно не находится")
    wired.closeSearch()
    // Открытая и снятая-поставленная настройка: открытие не переживает смену.
    wired.beginEdit(wired.spaces[0])
    wired.editor?.hidesContent = false
    wired.commitEditor()
    wired.beginEdit(wired.spaces[0])
    wired.editor?.hidesContent = true
    wired.commitEditor()
    check(wired.isConcealed(wired.allItems[0]), "сняли и поставили снова: снова скрыта")
    wired.reveal(id)
    stand.host.hide()
    check(wired.revealed.isEmpty && wired.isConcealed(wired.allItems[0]), "при закрытии панели всё скрывается сразу, ещё во время ухода")
    _ = await waitUntil { stand.settledGone }
    await stand.open()
    check(wired.isConcealed(controller.items[0]), "при новом показе запись снова скрыта")
    wired.allItems = controller.items
    wired.spaces = controller.spaces
    wired.reveal(id)
    wired.reset()
    check(wired.revealed.isEmpty, "сброс показа тоже закрывает")

    // Вставка и перенос отдают настоящее.
    let board = NSPasteboard(name: NSPasteboard.Name("local.utilitumus.test.conceal.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    _ = ClipboardPasteboard.write(controller.items[0], imageData: nil, to: board)
    check(board.string(forType: .string) == "пароль-qwerty", "вставка скрытой записи отдаёт настоящее")
    let provider = wired.dragProvider(for: controller.items[0])
    let carried = await loaded(provider, "public.utf8-plain-text")
    check(carried.flatMap { String(data: $0, encoding: .utf8) } == "пароль-qwerty", "перенос скрытой записи отдаёт настоящее")
    var pastedText: String?
    wired.onPaste = { pastedText = $0.text }
    wired.selectTab(spaceID)
    wired.quickPick(1)
    check(pastedText == "пароль-qwerty", "⌘1 у скрытой отдаёт настоящую запись")
}

/// Что утилита отправляет центру: строгая сверка ключей, содержимого скрытых записей там нет.
@MainActor func checkConcealedWire() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-wire-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ClipboardStore(directory: dir, key: SymmetricKey(size: .bits256), limit: 100)
    let controller = ClipboardController.shared
    defer { controller.detachStore() }
    let space = store.addSpace(name: "пароли", colorID: "red", hidesContent: true)
    let secret = "секрет-в-буфере"
    store.ingest(ClipSnapshot(types: [], filePaths: ["/tmp/секретный-файл.pdf"], sourceBundleID: "com.apple.finder"))
    store.pin(store.items[0].id, to: space.id)
    store.ingest(ClipSnapshot(types: [], text: "https://secret.example.com/x"))
    store.pin(store.items[0].id, to: space.id)
    store.ingest(ClipSnapshot(types: [], text: secret, sourceBundleID: "com.apple.Notes", sourceName: "Заметки"))
    store.pin(store.items[0].id, to: space.id)
    store.setTitle(store.items[0].id, "Пароль от почты")
    store.ingest(ClipSnapshot(types: [], text: "обычная запись"))
    controller.attach(store)

    let state = controller.wireState
    let data = LinkWire.encoded(state)
    let json = String(data: data, encoding: .utf8) ?? ""
    let titles = state.recent.map(\.title)
    check(titles == ["обычная запись", "Пароль от почты", "Скрыто", "Скрыто"], "строки: название или «Скрыто», у обычной текст: \(titles)")
    for leak in [secret, "secret.example", "секретный-файл", "hidesContent", "spaceRank"] {
        check(!json.contains(leak), "в состоянии для центра нет «\(leak)»")
    }
    // Договор связи прежний: те же ключи в тех же местах, что читает вышедший центр.
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let spaceKeys = ((object?["spaces"] as? [[String: Any]])?.first?.keys).map(Set.init)
    check(spaceKeys == ["id", "name", "colorID"], "ключи пространства прежние: \(String(describing: spaceKeys))")
    let rowKeys = (object?["recent"] as? [[String: Any]])?.map { Set($0.keys) }
    check(rowKeys?.allSatisfy { $0.isSubset(of: ["title", "sourceBundleID", "date"]) } == true, "ключи строки прежние: \(String(describing: rowKeys))")
    let decoded = try? JSONDecoder().decode(ClipboardState.self, from: data)
    check(decoded?.recent.map(\.title) == titles && decoded?.spaces.first?.hidesContent == nil, "состояние читается обратно")
    check(controller.recent.map(\.title) == titles, "экран утилиты показывает те же строки, а не текст")
    check(state.recent[1].sourceBundleID == "com.apple.Notes", "значок программы на месте")
    store.setSpaceHidden(space.id, false)
    controller.attach(store)
    check(controller.wireState.recent.map(\.title).contains(secret), "сняли скрытие: строка снова с текстом")
}

@main
enum Main {
    static func main() {
        setbuf(stdout, nil)
        let out = CommandLine.arguments[1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            // Ленты кадров вместо проверок: Tests/ClipboardPanelFilm.swift.
            if let films = ProcessInfo.processInfo.environment["CLIPBOARD_FILM_DIR"] { await runFilms(out: films) }
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
            await checkPanelSpeed()
            checkSelectionLogic()
            await checkMultiSelect(out: out)
            await checkPasteMany()
            checkReorderLogic()
            await checkMotionRules(out: out)
            await checkRecordOrder(out: out)
            await checkSpaceOrder(out: out)
            await checkTitle(out: out)
            await checkConcealment(out: out)
            await checkConcealedWire()
            print(failures == 0 ? "ГОТОВО: всё верно" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
