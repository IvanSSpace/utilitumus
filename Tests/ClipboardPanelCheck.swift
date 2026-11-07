import AppKit
import CryptoKit
import SwiftUI

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
            await checkLiveEvents()
            await checkScreens(out: out)
            print(failures == 0 ? "ГОТОВО: всё верно" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
