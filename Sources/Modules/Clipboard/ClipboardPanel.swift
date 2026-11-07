import SwiftUI
import AppKit

// Палитра, время и маленький значок лежат в UI/ClipboardShared.swift: их берёт и экран в лаунчере.
@MainActor
extension ClipSourceIcon {
    private static var large: [String: NSImage] = [:]

    /// Крупный значок для шапки карточки: копия с другим размером, маленькую берёт экран утилиты.
    static func largeImage(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = large[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        large[bundleID] = icon
        return icon
    }
}

// MARK: - Модель панели

/// Нажатая клавиша без AppKit: так очередь клавиш проверяется без настоящих событий.
struct ClipPanelKey {
    var code: UInt16
    var command = false
    var control = false
    var shift = false
    var text: String?

    var digit: Int? { text.flatMap { Int($0) } }

    /// Буква, цифра, знак: то, что можно набрать в поиске. Стрелки и функциональные клавиши приходят символами личной зоны.
    var isPlainText: Bool {
        guard !command, !control, code != 49, let text, !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .format, .surrogate, .unassigned: return false
            default: return true
            }
        }
    }
}

/// Окошко настроек категории (цвет, скрытие, удаление) в самой панели. Не NSPopover: его окно не из неактивирующих, клик в нём мог бы активировать
/// утилиту и забрать фокус у программы, куда потом вставляем.
struct ClipSpaceEditor: Equatable {
    enum Mode: Equatable {
        case edit(UUID)
        case confirmDelete(UUID)
        case confirmDeleteRecords([UUID])
    }

    var mode: Mode
    var name = ""
    var colorID = ClipPalette.all[0].id
    var hidesContent = false
}

/// Правка названия карточки: что правим и текущий текст.
struct ClipTitleEdit: Equatable {
    var id: UUID
    var text: String
}

/// Правка имени категории прямо в верхнем ряду. `isNew` — только что созданная: Esc её удаляет, а не оставляет.
struct ClipSpaceNameEdit: Equatable {
    var id: UUID
    var text: String
    var isNew: Bool
}

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var allItems: [ClipItem] = []
    @Published var spaces: [ClipSpace] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selected = 0
            selection.reset()
            clicks.reset()
            scrollToFirst()
            // Текст мог прийти и мимо клавиш (вставка в поле). Стёртый текст поиск не закрывает, это делает Esc.
            if !query.isEmpty { searchOpen = true }
        }
    }
    /// Поиск раскрыт: широкое поле, категории сжаты до точек, рамка выбранной карточки серая.
    @Published private(set) var searchOpen = false
    /// nil — вкладка «История».
    @Published var tab: UUID?
    @Published var selected = 0
    /// Истории нет из-за ошибки хранилища: вместо «История пуста» говорим об этом.
    @Published var storeError: String?
    @Published var theme = DSTheme.dusk
    @Published var editor: ClipSpaceEditor?
    /// К чему прокрутить ленту. Только клавиатура и смена списка: карточка под курсором не должна уезжать между двумя кликами.
    private(set) var scrollRequest: UUID?
    @Published private(set) var scrollTick = 0
    /// Момент показа: от него считается «N минут назад». Панель живёт между показами, и карточка иначе не обновила бы время.
    @Published private(set) var shownAt = Date()
    /// Вернуть фокус в поле поиска.
    @Published private(set) var focusRequest = 0
    @Published private(set) var selection = ClipSelection()
    /// Клавиши при клике: жест их не сообщает. Проверка подставляет свои.
    var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// Клик по одной из выбранных: сбросить до неё, если второго клика не будет.
    private var pendingCollapse: UUID?
    /// Скорости панели, для галочек в меню. Сама панель читает их из настроек при каждом показе и уходе.
    @Published private(set) var showSpeed = ClipPanelSpeed.parse(Kit.defaults.string(forKey: ClipboardPanelHost.showSpeedKey))
    @Published private(set) var hideSpeed = ClipPanelSpeed.parse(Kit.defaults.string(forKey: ClipboardPanelHost.hideSpeedKey))
    @Published var titleEdit: ClipTitleEdit?
    /// Записи скрытых категорий, открытые на время. Только до закрытия панели.
    @Published private(set) var revealed: Set<UUID> = []
    @Published var spaceNameEdit: ClipSpaceNameEdit?
    /// Куда встанет то, что несут: nil — курсор не над своим рядом. Сам порядок не меняется до отпускания кнопки, соседи только сдвинуты.
    @Published private(set) var recordSlot: Int?
    @Published private(set) var spaceSlot: Int?
    /// Что несут. Узнаём у самого источника: приёмник видит содержимое только при броске.
    private(set) var draggedRecord: UUID?
    private(set) var draggedSpace: UUID?
    /// Прокрутка в обрез, а не к центру: при переносе лента едет, только когда курсор у края.
    private(set) var scrollsMinimally = false
    private(set) var scrollAnimated = true
    /// Курсор в координатах панели, от левого верхнего угла. Панель даёт его сама, проверка подставляет свой.
    var pointer: () -> CGPoint? = { nil }
    var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Где лежат лента и её содержимое, в координатах панели. Без `@Published`: при прокрутке они меняются на каждый кадр.
    var stripFrames: [String: CGRect] = [:]
    var spaceFrames: [String: CGRect] = [:]
    /// Кадры вкладок на момент взятия: дальше вкладки сдвинуты, и места считались бы по сдвинутым.
    private var spaceRest: [UUID: CGRect] = [:]
    private var dragTimer: Timer?
    /// Лимит истории: для честной подписи при удалении пространства.
    var limit = ClipboardPolicy.defaultLimit

    var imageLoader: (ClipItem) -> NSImage? = { _ in nil }
    /// Как достать сохранённые байты картинки для переноса наружу. Возвращает загрузчик: сама расшифровка только по запросу программы.
    var imageBytes: (ClipItem) -> @Sendable () -> Data? = { _ in { nil } }
    var onPaste: (ClipItem) -> Void = { _ in }
    /// Несколько записей по очереди, слева направо.
    var onPasteMany: ([ClipItem]) -> Void = { _ in }
    var onPin: (UUID, UUID?) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onSetTitle: (UUID, String?) -> Void = { _, _ in }
    var onMoveRecord: (UUID, Int) -> Void = { _, _ in }
    var onMoveSpace: (UUID, Int) -> Void = { _, _ in }
    var onAddSpace: (String, String, Bool) -> Void = { _, _, _ in }
    var onSetSpaceHidden: (UUID, Bool) -> Void = { _, _ in }
    var onRenameSpace: (UUID, String) -> Void = { _, _ in }
    var onSetSpaceColor: (UUID, String) -> Void = { _, _ in }
    var onDeleteSpace: (UUID) -> Void = { _ in }
    /// nil — открыть настройки неоткуда, пункта в меню нет.
    var onOpenSettings: (() -> Void)?

    private var clicks = ClipClickTracker()
    private let images = NSCache<NSUUID, NSImage>()

    init() { images.countLimit = 24 }

    /// В «Истории» видно всё, что есть; во вкладке пространства — только его записи.
    var visible: [ClipItem] { ClipboardStore.filter(allItems, space: tab, query: query, spaces: spaces) }

    func setShowSpeed(_ speed: ClipPanelSpeed) {
        showSpeed = speed
        Kit.defaults.set(speed.rawValue, forKey: ClipboardPanelHost.showSpeedKey)
    }

    func setHideSpeed(_ speed: ClipPanelSpeed) {
        hideSpeed = speed
        Kit.defaults.set(speed.rawValue, forKey: ClipboardPanelHost.hideSpeedKey)
    }

    /// Что показывает лента: вкладка и запрос.
    var stripIdentity: String { "\(tab?.uuidString ?? "")|\(query)" }

    var selectedItem: ClipItem? {
        let list = visible
        return list.indices.contains(selected) ? list[selected] : nil
    }

    /// `extending` — Shift+стрелка: диапазон от якоря тянется вслед за выбором.
    func move(_ delta: Int, extending: Bool = false) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.indices.contains(selected) ? list[selected].id : nil
        selected = min(max(selected + delta, 0), list.count - 1)
        if extending {
            selection.extend(to: list[selected].id, from: current, in: list.map(\.id))
        } else {
            selection.reset()
        }
        pendingCollapse = nil
        requestScroll(to: list[selected].id)
    }

    var isMultiSelected: Bool { selection.isMultiple }

    /// Рамка: на всех выбранных или на единственной текущей.
    func hasRing(_ item: ClipItem, at index: Int) -> Bool {
        selection.isMultiple ? selection.ids.contains(item.id) : index == selected
    }

    /// Выбранные слева направо.
    var selectedItems: [ClipItem] {
        guard selection.isMultiple else { return selectedItem.map { [$0] } ?? [] }
        return visible.filter { selection.ids.contains($0.id) }
    }

    func clearSelection() {
        selection.reset()
        pendingCollapse = nil
    }

    /// Вставить все выбранные: по одной, слева направо. Одна — обычная вставка.
    func pasteSelected() {
        let items = selectedItems
        if items.count > 1 {
            onPasteMany(items)
        } else if let item = items.first {
            onPaste(item)
        }
    }

    func pinSelected(to space: UUID) {
        let ids = selectedItems.map(\.id)
        clearSelection()
        withAnimation(ClipMotion.move) {
            for id in ids {
                revealed.remove(id)
                onPin(id, space)
            }
        }
    }

    /// «Удалить N»: подтверждение тем же окошком, что у категории, без модального окна.
    func beginDeleteSelected() {
        let ids = selectedItems.map(\.id)
        guard ids.count > 1 else { return }
        commitInlineEdit()
        editor = ClipSpaceEditor(mode: .confirmDeleteRecords(ids))
    }

    private func scrollToFirst() {
        // Новое содержимое появляется сразу с начала: прокрутка анимацией тащила бы через него карточки.
        requestScroll(to: visible.first?.id, animated: false)
    }

    private func requestScroll(to id: UUID?, minimally: Bool = false, animated: Bool = true) {
        scrollRequest = id
        scrollsMinimally = minimally
        scrollAnimated = animated
        scrollTick += 1
    }

    func quickPick(_ number: Int) {
        let list = visible
        guard list.indices.contains(number - 1) else { return }
        clearSelection()
        onPaste(list[number - 1])
    }

    func selectTab(_ id: UUID?) {
        tab = id
        selected = 0
        clearSelection()
        clicks.reset()
        scrollToFirst()
    }

    func cycleTab(_ delta: Int) {
        let ids: [UUID?] = [nil] + spaces.map { Optional($0.id) }
        let current = ids.firstIndex(of: tab) ?? 0
        selectTab(ids[(current + delta + ids.count) % ids.count])
    }

    /// Клик по карточке: выделение сразу, вставка только вторым кликом в пределах окна.
    /// Shift и ⌘ только выбирают, вторым кликом вставки не считаются. Второй клик по одной из выбранных вставляет все, а первый
    /// сбрасывает до неё, только если второго не было: иначе двойной клик по выбранным вставил бы одну.
    func click(_ item: ClipItem, at index: Int, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pendingCollapse = nil
        let flags = modifiers()
        if flags.contains(.shift) {
            let list = visible
            selection.extend(to: item.id, from: selectedItem?.id, in: list.map(\.id))
            selected = index
            clicks.reset()
            return
        }
        if flags.contains(.command) {
            let list = visible
            let focus = selection.toggle(item.id, current: selectedItem?.id, in: list.map(\.id))
            if let at = list.firstIndex(where: { $0.id == focus }) { selected = at }
            clicks.reset()
            return
        }
        if selection.isMultiple, selection.ids.contains(item.id) {
            selected = index
            if clicks.click(item.id, at: time) == .paste {
                pasteSelected()
            } else {
                pendingCollapse = item.id
                DispatchQueue.main.asyncAfter(deadline: .now() + ClipClickTracker.pasteWindow) { [weak self] in
                    MainActor.assumeIsolated { self?.collapsePending(item.id) }
                }
            }
            return
        }
        selection.reset()
        selected = index
        if clicks.click(item.id, at: time) == .paste { onPaste(item) }
    }

    /// Второго клика не было: выбор сжимается до той карточки, по которой кликнули.
    func collapsePending(_ id: UUID) {
        guard pendingCollapse == id else { return }
        pendingCollapse = nil
        selection.reset()
    }

    func reset() {
        query = ""
        searchOpen = false
        tab = nil
        selected = 0
        editor = nil
        titleEdit = nil
        spaceNameEdit = nil
        clearSelection()
        forgetTemporary()
        clicks.reset()
        shownAt = Date()
        scrollToFirst()
        focusRequest += 1
    }

    /// Тему меняют в другой программе (лаунчере), поэтому она читается заново при каждом показе.
    func refreshTheme() {
        CustomPaletteStore.shared.reload()
        let raw = Kit.defaults.string(forKey: DSTheme.storageKey) ?? DSTheme.dusk.rawValue
        theme = raw == "custom" ? .custom(CustomPaletteStore.shared.palette) : DSTheme(rawValue: raw) ?? .dusk
    }

    /// Картинка карточки: расшифровка с диска не должна идти на каждую перерисовку, иначе клик тормозит.
    func image(_ item: ClipItem) -> NSImage? {
        let key = item.id as NSUUID
        if let hit = images.object(forKey: key) { return hit }
        guard let image = imageLoader(item) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    func forgetImages() { images.removeAllObjects() }

    /// Панель закрывается: правка сохраняется, как при клике мимо, открытое на время снова скрыто.
    func panelClosing() {
        commitInlineEdit()
        forgetTemporary()
    }

    private func forgetTemporary() {
        revealed = []
        stopDragTracking()
        recordSlot = nil
        spaceSlot = nil
        draggedRecord = nil
        draggedSpace = nil
    }

    // MARK: Скрытие

    /// Карточка сейчас без содержимого. Копия при переносе скрыта и у открытой на время: см. `ClipCard`.
    func isConcealed(_ item: ClipItem) -> Bool {
        ClipConcealment.isHidden(item, in: spaces) && !revealed.contains(item.id)
    }

    func reveal(_ id: UUID) { revealed.insert(id) }
    func conceal(_ id: UUID) { revealed.remove(id) }

    /// Закрепить запись. Открытая на время в другой категории в новой снова скрыта.
    /// Один анимированный переход на всё: точка на карточке и смыкание соседних, если запись ушла из открытой вкладки.
    func pin(_ id: UUID, to space: UUID?) {
        revealed.remove(id)
        withAnimation(ClipMotion.move) { onPin(id, space) }
    }

    /// Удалить запись: соседние смыкаются.
    func delete(_ id: UUID) {
        withAnimation(ClipMotion.move) { onDelete(id) }
    }

    // MARK: Перетаскивание

    func dragProvider(for item: ClipItem) -> NSItemProvider {
        // Переносится только одна карточка: выбор сжимается до неё.
        if selection.isMultiple {
            clearSelection()
            if let index = visible.firstIndex(where: { $0.id == item.id }) { selected = index }
        }
        draggedRecord = canReorderRecords ? item.id : nil
        draggedSpace = nil
        startDragTracking()
        return ClipDrag.provider(for: item, loadImage: imageBytes(item))
    }

    func spaceDragProvider(for id: UUID) -> NSItemProvider {
        draggedSpace = canReorderSpaces ? id : nil
        draggedRecord = nil
        spaceRest = Dictionary(uniqueKeysWithValues: spaces.compactMap { space in
            spaceFrames[space.id.uuidString].map { (space.id, $0) }
        })
        startDragTracking()
        return ClipDrag.spaceProvider(for: id)
    }

    func acceptDroppedRecord(_ id: UUID, on space: UUID) {
        guard allItems.contains(where: { $0.id == id }), spaces.contains(where: { $0.id == space }) else { return }
        pin(id, to: space)
    }

    /// Порядок карточек есть только во вкладке категории и не при поиске: в выдаче соседи не настоящие.
    var canReorderRecords: Bool { tab != nil && !searchOpen && query.isEmpty }
    /// При поиске категории сжаты до точек.
    var canReorderSpaces: Bool { !searchOpen }

    /// Выбор остаётся на той же записи, хотя её номер в ленте поменялся.
    private func keepingSelection(_ change: () -> Void) {
        let id = selectedItem?.id
        change()
        if let id, let index = visible.firstIndex(where: { $0.id == id }) { selected = index }
    }

    // Перестановка идёт по самому курсору и кнопке, как боковая панель лаунчера, а не по событиям приёмника SwiftUI: на настоящей панели
    // перенос внутри ленты через них не заработал, хотя подставной сеанс проходил. Приёмник только говорит системе «сюда можно».
    // От источника нужен один `onDrag`, а он работает: бросок на категорию идёт через него же.

    private func startDragTracking() {
        stopDragTracking()
        recordSlot = nil
        spaceSlot = nil
        guard draggedRecord != nil || draggedSpace != nil else { return }
        ClipDragLog.log.info("перенос начат: запись \(self.draggedRecord != nil), категория \(self.draggedSpace != nil)")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    var isTrackingDrag: Bool { dragTimer != nil }

    /// Шаг переноса: кнопку отпустили — итог, иначе место под курсором.
    func dragTick() {
        guard draggedRecord != nil || draggedSpace != nil else {
            stopDragTracking()
            return
        }
        if isMouseDown() { updateDragSlots() } else { finishDrag() }
    }

    /// Бросок или отпущенная кнопка. Вызов второй раз ничего не делает, поэтому приёмнику и таймеру можно не договариваться, кто первый.
    func finishDrag() {
        stopDragTracking()
        guard draggedRecord != nil || draggedSpace != nil else { return }
        updateDragSlots()
        let record = draggedRecord, space = draggedSpace
        let toRecord = recordSlot, toSpace = spaceSlot
        ClipDragLog.log.info("перенос окончен: место записи \(toRecord ?? -1), категории \(toSpace ?? -1)")
        draggedRecord = nil
        draggedSpace = nil
        // Без анимации: соседи уже стоят на новых местах, порядок только подтверждает то, что видно.
        var settled = Transaction()
        settled.disablesAnimations = true
        withTransaction(settled) {
            keepingSelection {
                recordSlot = nil
                spaceSlot = nil
                if let record, let toRecord, canReorderRecords, visible.contains(where: { $0.id == record }) { onMoveRecord(record, toRecord) }
                if let space, let toSpace, canReorderSpaces, spaces.contains(where: { $0.id == space }) { onMoveSpace(space, toSpace) }
            }
        }
    }

    private func updateDragSlots() {
        let point = pointer()
        if draggedRecord != nil {
            let slot = point.flatMap(recordSlot(under:))
            guard slot != recordSlot else { return }
            ClipDragLog.log.info("место записи \(slot ?? -1)")
            withAnimation(ClipMotion.move) { recordSlot = slot }
            // Только у края: лента едет, открывая следующих соседей. Иначе прокрутка шла бы поверх движения соседей.
            if let slot, visible.indices.contains(slot), let strip = stripFrames[ClipStripKey.strip], let content = stripFrames[ClipStripKey.content] {
                let x = content.minX + ClipPanelMetrics.ringRoom + CGFloat(slot) * (ClipCard.width + ClipPanelMetrics.cardGap)
                if x < strip.minX || x + ClipCard.width > strip.maxX { requestScroll(to: visible[slot].id, minimally: true) }
            }
        } else if draggedSpace != nil {
            let slot = point.flatMap(spaceSlot(under:))
            guard slot != spaceSlot else { return }
            withAnimation(ClipMotion.move) { spaceSlot = slot }
        }
    }

    private func recordSlot(under point: CGPoint) -> Int? {
        guard let strip = stripFrames[ClipStripKey.strip], let content = stripFrames[ClipStripKey.content], strip.contains(point) else { return nil }
        return ClipReorder.slot(x: Double(point.x - content.minX - ClipPanelMetrics.ringRoom),
                                others: Array(repeating: Double(ClipCard.width), count: max(0, visible.count - 1)),
                                dragged: Double(ClipCard.width), gap: Double(ClipPanelMetrics.cardGap))
    }

    /// Над «Буфером обмена» места нет: левее него встать нельзя. Правее ряда запас, там последнее место.
    private func spaceSlot(under point: CGPoint) -> Int? {
        let frames = spaces.compactMap { spaceRest[$0.id] }
        guard let dragged = draggedSpace, let width = spaceRest[dragged]?.width, frames.count == spaces.count,
              let first = frames.first, let last = frames.last,
              point.x >= first.minX - 4, point.x <= last.maxX + 60, abs(point.y - first.midY) <= first.height else { return nil }
        return ClipReorder.slot(x: Double(point.x - first.minX),
                                others: spaces.filter { $0.id != dragged }.map { Double(spaceRest[$0.id]?.width ?? 0) },
                                dragged: Double(width), gap: Double(ClipPanelMetrics.spaceGap))
    }

    /// Сдвиг карточки при переносе: место одной карточки, у самой переносимой — сколько мест она прошла.
    func recordShift(at index: Int, draggedAt from: Int?) -> CGFloat {
        guard let from, let recordSlot else { return 0 }
        return CGFloat(ClipReorder.shift(index, from: from, to: recordSlot)) * (ClipCard.width + ClipPanelMetrics.cardGap)
    }

    /// То же для вкладки: ширины у них разные.
    func spaceShift(_ id: UUID) -> CGFloat {
        guard let spaceSlot, let dragged = draggedSpace, let from = spaces.firstIndex(where: { $0.id == dragged }),
              let index = spaces.firstIndex(where: { $0.id == id }) else { return 0 }
        func step(_ id: UUID) -> CGFloat { (spaceRest[id]?.width ?? 0) + ClipPanelMetrics.spaceGap }
        guard index == from else { return CGFloat(ClipReorder.shift(index, from: from, to: spaceSlot)) * step(dragged) }
        let passed = spaceSlot > from ? spaces[(from + 1)...spaceSlot] : spaces[spaceSlot..<from]
        return passed.reduce(0) { $0 + step($1.id) } * (spaceSlot > from ? 1 : -1)
    }

    // MARK: Название

    /// Клик по заголовку: у выбранной карточки правка, а второй клик здесь не вставляет. У остальных обычный клик по карточке.
    func clickTitle(_ item: ClipItem, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let plain = modifiers().intersection([.shift, .command]).isEmpty && !selection.isMultiple
        if plain, selectedItem?.id == item.id {
            beginTitleEdit(item)
        } else if let index = visible.firstIndex(where: { $0.id == item.id }) {
            click(item, at: index, time: time)
        }
    }

    func beginTitleEdit(_ item: ClipItem) {
        commitInlineEdit()
        clicks.reset()
        if let index = visible.firstIndex(where: { $0.id == item.id }) { selected = index }
        titleEdit = ClipTitleEdit(id: item.id, text: item.title ?? "")
    }

    /// Enter, клик мимо, закрытие панели. Пустое имя убирает название.
    func commitTitleEdit() {
        guard let edit = titleEdit else { return }
        titleEdit = nil
        let clean = ClipboardStore.cleanTitle(edit.text)
        if allItems.first(where: { $0.id == edit.id })?.title != clean { onSetTitle(edit.id, clean) }
        focusRequest += 1
    }

    func cancelTitleEdit() {
        guard titleEdit != nil else { return }
        titleEdit = nil
        focusRequest += 1
    }

    // MARK: Имя категории на месте

    static let untitled = "Без названия"

    var isEditingInline: Bool { titleEdit != nil || spaceNameEdit != nil }

    func commitInlineEdit() {
        commitTitleEdit()
        commitSpaceName()
    }

    func cancelInlineEdit() {
        cancelTitleEdit()
        cancelSpaceName()
    }

    func beginRename(_ space: ClipSpace) {
        commitInlineEdit()
        spaceNameEdit = ClipSpaceNameEdit(id: space.id, text: space.name, isNew: false)
    }

    /// Пустое имя у новой оставляет «Без названия», у старой — прежнее. Вкладка новой открывается только здесь.
    func commitSpaceName() {
        guard let edit = spaceNameEdit else { return }
        spaceNameEdit = nil
        let current = spaces.first { $0.id == edit.id }?.name
        let name = ClipboardWireRules.cleanName(edit.text) ?? current ?? Self.untitled
        if current != name { onRenameSpace(edit.id, name) }
        if edit.isNew { selectTab(edit.id) }
        focusRequest += 1
    }

    /// Esc: новую, ещё пустую категорию убирает совсем, у старой оставляет имя.
    func cancelSpaceName() {
        guard let edit = spaceNameEdit else { return }
        spaceNameEdit = nil
        if edit.isNew { onDeleteSpace(edit.id) }
        focusRequest += 1
    }

    // MARK: Поиск

    func openSearch() {
        searchOpen = true
        focusRequest += 1
    }

    func closeSearch() {
        query = ""
        searchOpen = false
        focusRequest += 1
    }

    /// Запасной путь, когда поле не в фокусе; обычно буквы приходят из самого поля.
    func typeIntoSearch(_ text: String) {
        query += text
        focusRequest += 1
    }

    // MARK: Клавиши

    /// true — клавишу забрала панель. Порядок Esc: окошко категории, затем поиск, затем панель.
    func handleKey(_ key: ClipPanelKey) -> Bool {
        if let editor {
            switch key.code {
            case 53: self.editor = nil; focusRequest += 1; return true
            case 36, 76: commitEditor(); return true
            default:
                // В подтверждении удаления нет поля: буквы иначе ушли бы в поиск за его спиной.
                // Поля в окошке нет: буквы иначе ушли бы в поиск за его спиной.
                return true
            }
        }
        if isEditingInline {
            switch key.code {
            case 53: cancelInlineEdit(); return true
            case 36, 76, 48: commitInlineEdit(); return true
            default: return false   // Всё остальное принадлежит полю: буквы, стрелки, ⌘1–9.
            }
        }
        if key.command, let digit = key.digit, (1...9).contains(digit) {
            quickPick(digit)
            return true
        }
        switch key.code {
        case 123: move(-1, extending: key.shift); return true  // ←
        case 124: move(1, extending: key.shift); return true   // →
        case 36, 76:                                  // Enter
            pasteSelected()
            return true
        case 53:                                      // Esc: сначала выбор, потом поиск, потом панель
            if selection.isMultiple { clearSelection() } else if searchOpen { closeSearch() } else { onClose() }
            return true
        case 48: cycleTab(key.shift ? -1 : 1); return true  // Tab
        case 51 where key.command:                    // ⌘⌫ — удалить запись
            if selection.isMultiple { beginDeleteSelected() } else if let item = selectedItem { delete(item.id) }
            return true
        default:
            guard !searchOpen, !key.command else { return false }
            // Поиск раскрывается по самой клавише, а не по тексту в поле: у IME и мёртвых клавиш (символов нет) текст придёт позже,
            // а набор должен быть виден сразу. Пробел, стрелки и Delete скрытому полю незачем.
            if key.isPlainText || key.text?.isEmpty == true {
                searchOpen = true
                return false
            }
            return true
        }
    }

    // MARK: Пространства

    /// Без хранилища новое пространство сохранить негде: кнопка не должна обещать.
    var canAddSpace: Bool { storeError == nil && spaces.count < ClipboardWireRules.maxSpaces }

    /// Кнопка +: категория появляется сразу, уже с полем имени. Цвет первый незанятый, все заняты — по очереди.
    func beginCreate() {
        guard canAddSpace else { return }
        commitInlineEdit()
        let used = Set(spaces.map(\.colorID))
        let color = ClipPalette.all.first { !used.contains($0.id) }?.id ?? ClipPalette.nextID(after: spaces.count)
        let before = Set(spaces.map(\.id))
        onAddSpace(Self.untitled, color, false)
        guard let space = spaces.first(where: { !before.contains($0.id) }) else { return }
        spaceNameEdit = ClipSpaceNameEdit(id: space.id, text: Self.untitled, isNew: true)
    }

    func beginEdit(_ space: ClipSpace) {
        editor = ClipSpaceEditor(mode: .edit(space.id), name: space.name, colorID: space.colorID, hidesContent: space.hidesContent == true)
    }

    func beginDelete(_ space: ClipSpace) {
        editor = ClipSpaceEditor(mode: .confirmDelete(space.id), name: space.name, colorID: space.colorID)
    }

    func closeEditor() {
        editor = nil
        focusRequest += 1
    }

    /// Сохранить настройки категории.
    /// Удаление здесь не идёт: Enter не должен подтверждать его случайно, только кнопка `confirmDelete`.
    func commitEditor() {
        guard let editor else { return }
        switch editor.mode {
        case .edit(let id):
            guard let space = spaces.first(where: { $0.id == id }) else { break }
            if space.colorID != editor.colorID { onSetSpaceColor(id, editor.colorID) }
            if (space.hidesContent == true) != editor.hidesContent {
                onSetSpaceHidden(id, editor.hidesContent)
                // Сняли и поставили снова: открытые раньше записи опять скрыты.
                revealed = []
            }
        case .confirmDelete, .confirmDeleteRecords:
            return
        }
        closeEditor()
    }

    func confirmDelete() {
        if case .confirmDeleteRecords(let ids)? = editor?.mode {
            clearSelection()
            withAnimation(ClipMotion.move) { ids.forEach(onDelete) }
            closeEditor()
            return
        }
        guard case .confirmDelete(let id)? = editor?.mode else { return }
        onDeleteSpace(id)
        if tab == id { selectTab(nil) }
        closeEditor()
    }
}

// MARK: - Вид панели

/// Высоты панели: окно задаёт высоту, карточка получает всё, что осталось под верхним рядом.
enum ClipPanelMetrics {
    static let panelHeight: CGFloat = 334
    static let topPadding: CGFloat = 12
    static let barHeight: CGFloat = 36
    static let barGap: CGFloat = 13
    static let bottomPadding: CGFloat = 17
    /// Запас вокруг карточки под рамку выбора.
    static let ringRoom: CGFloat = 6
    static let cardHeight = panelHeight - topPadding - barHeight - barGap - bottomPadding - ringRoom * 2
    static let cardGap: CGFloat = 24
    static let searchWidth: CGFloat = 440
    static let spaceGap: CGFloat = 6
}

private struct ClipAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Где лента и её содержимое. Отдельно от вкладок: при прокрутке это меняется на каждый кадр, а перерисовка панели здесь не нужна.
struct ClipStripKey: PreferenceKey {
    static let strip = "strip"
    static let content = "content"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func clipStripFrame(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ClipStripKey.self, value: [name: geometry.frame(in: .named("clipPanel"))])
        })
    }

    /// Кнопка панели без системной рамки и без клавиатурного фокуса: клавиатура всегда у поля поиска или поля окошка,
    /// управление идёт через монитор клавиш. Иначе при «полном доступе с клавиатуры» окно отдаёт фокус первой кнопке ряда.
    func clipPanelButton() -> some View {
        buttonStyle(.plain).focusable(false)
    }

    /// Запомнить, где лежит кнопка: окошко категории откроется под ней.
    func clipAnchor(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ClipAnchorKey.self, value: [name: geometry.frame(in: .named("clipPanel"))])
        })
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool
    @State private var anchors: [String: CGRect] = [:]

    private let ink = Color.white

    var body: some View {
        VStack(spacing: ClipPanelMetrics.barGap) {
            topBar
            cards
        }
        .padding(.horizontal, 16)
        .padding(.top, ClipPanelMetrics.topPadding)
        .padding(.bottom, ClipPanelMetrics.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if model.editor != nil { editorLayer } }
        .coordinateSpace(name: "clipPanel")
        .onPreferenceChange(ClipAnchorKey.self) { frames in
            anchors = frames
            model.spaceFrames = frames
        }
        .onPreferenceChange(ClipStripKey.self) { model.stripFrames = $0 }
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .onAppear { focusSearch() }
        .onChange(of: model.focusRequest) { focusSearch() }
    }

    /// Поле поиска живёт всегда, только скрыто, и держит клавиатуру: буква сразу попадает в него со всей раскладкой и IME.
    /// Курсор в конец: при получении фокуса поле выделяет весь текст, и следующая буква стёрла бы предыдущую.
    private func focusSearch() {
        guard model.editor == nil, !model.isEditingInline else { return }
        searchFocused = true
        DispatchQueue.main.async {
            // Не только ключевое окно: панель может стать ключевой позже этого вызова.
            for window in NSApp.windows { (window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
        }
    }

    // MARK: Верхний ряд

    private var topBar: some View {
        HStack(spacing: 8) {
            // Противовес кнопке «…»: ряд стоит ровно по центру панели.
            Color.clear.frame(width: 34, height: 1)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: rowGap) {
                            searchField
                            historyTab
                            ForEach(model.spaces) { space in
                                Group {
                                    if model.searchOpen {
                                        spaceDot(space)
                                    } else if model.spaceNameEdit?.id == space.id {
                                        spaceNameField(space)
                                    } else {
                                        spaceTab(space)
                                    }
                                }
                                .id(space.id)
                            }
                            if !model.searchOpen { plusButton }
                        }
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    // Ряд мог не влезть: новая категория должна быть видна.
                    .onChange(of: model.spaceNameEdit?.id) {
                        guard let id = model.spaceNameEdit?.id else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id) }
                    }
                }
            }
            moreMenu
        }
        .frame(height: ClipPanelMetrics.barHeight)
    }

    private var rowGap: CGFloat { model.searchOpen ? 10 : ClipPanelMetrics.spaceGap }

    /// Имя категории прямо в ряду: и новой, и по «Переименовать». Рамка цвета акцента, как у поля поиска.
    private func spaceNameField(_ space: ClipSpace) -> some View {
        let text = model.spaceNameEdit?.text ?? ""
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let width = min(max((text as NSString).size(withAttributes: [.font: font]).width + 8, 60), 190)
        return HStack(spacing: 8) {
            Circle().fill(ClipPalette.color(space.colorID)).frame(width: 10, height: 10)
            ClipInlineField(placeholder: Self.untitledPlaceholder, font: .system(size: 13.5, weight: .medium),
                            text: Binding(get: { model.spaceNameEdit?.text ?? "" }, set: { model.spaceNameEdit?.text = $0 }))
                .frame(width: width)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(model.theme.accent(.clipboard), lineWidth: 2))
        .clipAnchor(space.id.uuidString)
    }

    private static var untitledPlaceholder: String { ClipboardPanelModel.untitled }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { model.openSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: model.searchOpen ? 14 : 16, weight: .regular))
                    .foregroundStyle(ink.opacity(model.searchOpen ? 0.7 : 0.8))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .clipPanelButton()
            .help("Поиск")
            TextField("Поиск", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .frame(width: model.searchOpen ? nil : 1)
                .opacity(model.searchOpen ? 1 : 0)
                .accessibilityHidden(!model.searchOpen)
        }
        .padding(.horizontal, model.searchOpen ? 8 : 4)
        .frame(width: model.searchOpen ? ClipPanelMetrics.searchWidth : 38, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(model.searchOpen ? 0.08 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(model.theme.accent(.clipboard), lineWidth: 2).opacity(model.searchOpen ? 1 : 0))
    }

    private var historyTab: some View {
        let active = model.tab == nil
        return Button { model.selectTab(nil) } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock").font(.system(size: 13.5))
                if !model.searchOpen {
                    Text("Буфер обмена").font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(ink.opacity(active ? 1 : 0.75))
            .padding(.horizontal, model.searchOpen ? 7 : 11).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(active ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .clipPanelButton()
        .help("Буфер обмена")
    }

    /// Перенос категории принимает та вкладка, что под курсором: все приёмники SwiftUI регистрируют один и тот же `public.data`,
    /// и общий приёмник на весь ряд перехватил бы и записи. `reach` — насколько приёмник шире самой вкладки.
    private func spaceDropEffect(_ space: ClipSpace, reach: CGFloat) -> ClipSpaceDropEffect {
        ClipSpaceDropEffect(color: ClipPalette.color(space.colorID), reach: reach, model: model) { dropCard($0, on: space.id) }
    }

    private func spaceLabel(_ space: ClipSpace, active: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ClipPalette.color(space.colorID)).frame(width: 10, height: 10)
            Text(space.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                .frame(maxWidth: 190, alignment: .leading)
        }
        .fixedSize()
        .foregroundStyle(ink.opacity(active ? 1 : 0.8))
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(active ? 0.14 : 0)))
        .contentShape(Rectangle())
    }

    /// Вкладка без `Button`: перенос и клик здесь устроены как у карточки, где этот способ уже работает в настоящем сеансе переноса.
    private func spaceTab(_ space: ClipSpace) -> some View {
        let active = model.tab == space.id
        return spaceLabel(space, active: active)
        // Приёмник и кадр в ряду снаружи: сдвинутая вкладка не уносит их из-под курсора.
        .opacity(model.spaceSlot != nil && model.draggedSpace == space.id ? 0 : 1)
        .offset(x: model.spaceShift(space.id))
        .accessibilityAddTraits(.isButton)
        .onTapGesture { model.selectTab(space.id) }
        .onDrag {
            model.spaceDragProvider(for: space.id)
        } preview: {
            spaceLabel(space, active: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.2)))
                .environment(\.colorScheme, .dark)
        }
        .help(space.name)
        .clipAnchor(space.id.uuidString)
        .contextMenu { spaceMenu(space) }
        // Половина зазора с каждой стороны: приёмники смыкаются, и между соседними вкладками бросок не пропадает.
        .modifier(spaceDropEffect(space, reach: ClipPanelMetrics.spaceGap / 2))
    }

    /// Категория на время поиска: только точка, название в подсказке.
    private func spaceDot(_ space: ClipSpace) -> some View {
        let active = model.tab == space.id
        return Button { model.selectTab(space.id) } label: {
            Circle().fill(ClipPalette.color(space.colorID)).frame(width: 12, height: 12)
                .frame(width: 26, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(active ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .clipPanelButton()
        .help(space.name)
        .accessibilityLabel(space.name)
        .clipAnchor(space.id.uuidString)
        .contextMenu { spaceMenu(space) }
        .modifier(spaceDropEffect(space, reach: 0))
    }

    /// Перетащил карточку на категорию — запись закрепилась в ней. Принимается только свой тип и только своя запись.
    private func dropCard(_ providers: [NSItemProvider], on space: UUID) -> Bool {
        guard let provider = ClipDrag.recordProvider(in: providers) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: ClipDrag.recordType.identifier) { data, _ in
            guard let id = data.flatMap(ClipDrag.recordID) else { return }
            DispatchQueue.main.async { model.acceptDroppedRecord(id, on: space) }
        }
        return true
    }

    @ViewBuilder private func spaceMenu(_ space: ClipSpace) -> some View {
        Button("Переименовать") { model.beginRename(space) }
        Button("Сменить цвет") { model.beginEdit(space) }
        Button("Скрывать содержимое") { model.beginEdit(space) }
        Divider()
        Button("Удалить", role: .destructive) { model.beginDelete(space) }
    }

    private var plusButton: some View {
        Button { model.beginCreate() } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink.opacity(model.canAddSpace ? 0.8 : 0.25))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .clipPanelButton()
        .disabled(!model.canAddSpace)
        .help("Новое пространство")
    }

    private func speedMenu(_ title: String, current: ClipPanelSpeed, set: @escaping (ClipPanelSpeed) -> Void) -> some View {
        Menu(title) {
            ForEach(ClipPanelSpeed.allCases) { speed in
                Toggle(speed.title, isOn: Binding(get: { current == speed }, set: { if $0 { set(speed) } }))
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let open = model.onOpenSettings {
                Button("Настройки Буфера…", action: open)
                Divider()
            }
            speedMenu("Появление", current: model.showSpeed, set: model.setShowSpeed)
            speedMenu("Закрытие", current: model.hideSpeed, set: model.setHideSpeed)
            Divider()
            ForEach(ClipPanelText.hints, id: \.key) { hint in
                Text("\(hint.key) — \(hint.text)")
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.opacity(0.8))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help("Подсказки и настройки")
    }

    // MARK: Окошко категории

    private var editorLayer: some View {
        GeometryReader { geometry in
            let width: CGFloat = 300
            let anchor = editorAnchor
            // Подтверждение для нескольких карточек — над лентой по центру: одного места у них нет.
            let center: Bool = { if case .confirmDeleteRecords? = model.editor?.mode { return true } else { return false } }()
            let x = center ? geometry.size.width / 2 : min(max(anchor.midX, width / 2 + 12), geometry.size.width - width / 2 - 12)
            ZStack(alignment: .topLeading) {
                // Клик мимо окошка закрывает его, а не срабатывает по карточке под ним.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeEditor() }
                ClipSpaceEditorView(model: model)
                    .frame(width: width)
                    .offset(x: x - width / 2, y: anchor.maxY + 6)
            }
        }
    }

    private var editorAnchor: CGRect {
        let fallback = CGRect(x: 0, y: ClipPanelMetrics.topPadding, width: 0, height: ClipPanelMetrics.barHeight)
        switch model.editor?.mode {
        case .edit(let id), .confirmDelete(let id): return anchors[id.uuidString] ?? fallback
        default: return fallback
        }
    }

    // MARK: Лента карточек

    private var cards: some View {
        let list = model.visible
        let from = model.draggedRecord.flatMap { id in list.firstIndex { $0.id == id } }
        return ZStack {
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(ink.opacity(0.3))
                    Text(emptyText).font(.system(size: 13)).foregroundStyle(ink.opacity(0.5))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: ClipPanelMetrics.cardGap) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, number: index < 9 ? index + 1 : nil,
                                         selected: model.hasRing(item, at: index), searching: model.searchOpen,
                                         theme: model.theme, spaces: model.spaces, now: model.shownAt, model: model,
                                         concealed: model.isConcealed(item), editingTitle: model.titleEdit?.id == item.id,
                                         groupCount: model.isMultiSelected && model.selection.ids.contains(item.id) ? model.selection.ids.count : 0)
                                    .id(item.id)
                                    // Сама она летит под курсором, здесь пустое место, вокруг которого расступаются соседи.
                                    .opacity(model.recordSlot != nil && index == from ? 0 : 1)
                                    .offset(x: model.recordShift(at: index, draggedAt: from))
                                    .transition(.opacity.animation(ClipMotion.fade))
                                    // Один обработчик: второй, на двойной клик, заставил бы одиночный ждать.
                                    .onTapGesture { model.click(item, at: index) }
                                    // Половина зазора с каждой стороны: цели смыкаются, между карточками бросок не пропадает.
                                    .padding(.horizontal, ClipPanelMetrics.cardGap / 2)
                                    .onDrop(of: [ClipDrag.recordType], delegate: ClipCardDropDelegate(model: model))
                                    .padding(.horizontal, -ClipPanelMetrics.cardGap / 2)
                            }
                        }
                        .padding(.horizontal, ClipPanelMetrics.ringRoom).padding(.vertical, ClipPanelMetrics.ringRoom)
                        .clipStripFrame(ClipStripKey.content)
                    }
                    .clipStripFrame(ClipStripKey.strip)
                    .onChange(of: model.scrollTick) {
                        guard let target = model.scrollRequest else { return }
                        let anchor: UnitPoint? = model.scrollsMinimally ? nil : .center
                        if model.scrollAnimated {
                            withAnimation(ClipMotion.fade) { proxy.scrollTo(target, anchor: anchor) }
                        } else {
                            proxy.scrollTo(target, anchor: anchor)
                        }
                    }
                }
                // Другая вкладка или выдача — другая лента: содержимое меняется затуханием, карточки никуда не летят.
                .id(model.stripIdentity)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ClipMotion.fade, value: model.stripIdentity)
    }

    private var emptyText: String {
        if let error = model.storeError { return error }
        if !model.query.isEmpty { return "Ничего не нашлось" }
        if let tab = model.tab, let space = model.spaces.first(where: { $0.id == tab }) {
            return "В «\(space.name)» пусто. Правый клик по карточке → «В пространство»"
        }
        return "История пуста. Скопируй что-нибудь"
    }
}

// MARK: - Окошко категории

private struct ClipSpaceEditorView: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .confirmDelete(let id)? = model.editor?.mode {
                confirmation(id)
            } else if case .confirmDeleteRecords(let ids)? = model.editor?.mode {
                recordsConfirmation(ids.count)
            } else {
                form
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var form: some View {
        Text(model.editor?.name ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        HStack(spacing: 6) {
            ForEach(ClipPalette.all, id: \.id) { entry in
                let chosen = entry.id == model.editor?.colorID
                Button { model.editor?.colorID = entry.id } label: {
                    Circle().fill(entry.color).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(.white.opacity(chosen ? 0.95 : 0.15), lineWidth: chosen ? 2 : 1))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .clipPanelButton()
                .help(entry.name)
                .accessibilityLabel(entry.name)
            }
        }
        hidesContentRow
        HStack {
            Spacer()
            actionButton("Отмена", prominent: false) { model.closeEditor() }
            actionButton("Сохранить", prominent: true) { model.commitEditor() }
        }
    }

    private var hidesContentRow: some View {
        let on = model.editor?.hidesContent == true
        return Button { model.editor?.hidesContent.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                    .foregroundStyle(on ? model.theme.accent(.clipboard) : .white.opacity(0.6))
                Text("Скрывать содержимое").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .clipPanelButton()
        .accessibilityValue(on ? "включено" : "выключено")
    }

    @ViewBuilder private func confirmation(_ id: UUID) -> some View {
        Text("Удалить «\(model.editor?.name ?? "")»?").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white).lineLimit(2)
        Text(ClipSpaceDeletion.summary(items: model.allItems, space: id, limit: model.limit))
            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            actionButton("Отмена", prominent: false) { model.closeEditor() }
            actionButton("Удалить", prominent: true, destructive: true) { model.confirmDelete() }
        }
    }

    @ViewBuilder private func recordsConfirmation(_ count: Int) -> some View {
        Text("Удалить \(count) \(ClipboardPreview.word(count, "запись", "записи", "записей"))?").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white).lineLimit(2)
        Text("Удалятся навсегда, и из категорий тоже.").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
        HStack {
            Spacer()
            actionButton("Отмена", prominent: false) { model.closeEditor() }
            actionButton("Удалить", prominent: true, destructive: true) { model.confirmDelete() }
        }
    }

    private func actionButton(_ title: String, prominent: Bool, destructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                    destructive ? Color(red: 0.75, green: 0.2, blue: 0.2)
                        : prominent ? model.theme.accent(.clipboard).opacity(0.75) : Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .clipPanelButton()
    }
}

// MARK: - Окно панели

/// Панель, которая берёт клавиатуру, но не делает Utilitumus активным: впереди остаётся та программа,
/// куда потом вставляем.
private final class ClipboardNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Источник `.onDrag` в SwiftUI разрешает только копирование, а приёмник категории предлагает перенос: операции вне разрешённых система
/// не обязана принимать. Поэтому внутри программы разрешён и перенос, а наружу по-прежнему только копия: Finder не переместит настоящий файл.
/// Метод SwiftUI закрыт для переопределения в Swift, селектор добавляется на этот подкласс, общий `NSHostingView` не меняется.
final class ClipPanelHostingView: NSHostingView<ClipboardPanelView> {
    #if KIT_TEST_DEFAULTS
    /// Сколько раз вид пересчитал раскладку: при движении окна её быть не должно.
    static var layoutCount = 0
    override func layout() {
        Self.layoutCount += 1
        super.layout()
    }
    #endif

    private static let dragMask: Void = {
        let selector = #selector(NSDraggingSource.draggingSession(_:sourceOperationMaskFor:))
        guard let inherited = class_getInstanceMethod(ClipPanelHostingView.self, selector) else { return }
        let mask: @convention(block) (AnyObject, AnyObject?, Int) -> UInt = { _, _, context in
            let allowed: NSDragOperation = context == NSDraggingContext.withinApplication.rawValue ? [.copy, .move] : .copy
            return allowed.rawValue
        }
        class_addMethod(ClipPanelHostingView.self, selector, imp_implementationWithBlock(mask), method_getTypeEncoding(inherited))
    }()

    static func make(_ root: ClipboardPanelView) -> ClipPanelHostingView {
        _ = dragMask
        return ClipPanelHostingView(rootView: root)
    }
}

@MainActor
final class ClipboardPanelHost {
    static let shared = ClipboardPanelHost()
    static let height = ClipPanelMetrics.panelHeight

    /// Утилита открывает своё окно настроек; у встроенного модуля пути нет, и пункта в меню тоже.
    var settingsOpener: (() -> Void)?
    /// false — только для показа автору: панель не закрывается от кликов мимо и смены программы.
    var hidesOnOutsideClick = true
    /// Стенд: где показать панель (иначе экран под курсором) и чем её сделать. Настоящая панель забрала бы клавиатуру у программы автора.
    var standFrame: CGRect?
    var panelMaker: (ClipboardPanelModel) -> NSPanel = { ClipboardPanelHost.makePanel($0) }
    var reducesMotion: () -> Bool = { ClipMotion.reduced }

    static let showSpeedKey = "Clipboard.ShowSpeed"
    static let hideSpeedKey = "Clipboard.HideSpeed"
    /// 0 — без анимации, как и при «Уменьшении движения», которое важнее настройки.
    private var showDuration: Double { reducesMotion() ? 0 : ClipPanelSpeed.parse(Kit.defaults.string(forKey: Self.showSpeedKey)).duration }
    private var hideDuration: Double { reducesMotion() ? 0 : ClipPanelSpeed.parse(Kit.defaults.string(forKey: Self.hideSpeedKey)).duration }
    static let slideDistance: CGFloat = 40

    private var panel: NSPanel?
    private var model: ClipboardPanelModel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalClick: Any?
    private var activation: NSObjectProtocol?
    /// Панель уезжает: окно ещё на экране, но для всех она уже закрыта, и горячая клавиша откроет её снова.
    private var isLeaving = false
    private var leftCallbacks: [() -> Void] = []
    /// Куда панель приезжает при показе. Уход считается от него: при закрытии посреди открытия текущий кадр ещё на полпути.
    private var shownFrame = CGRect.zero
    /// Номер показа. Завершение анимации сверяет его: закрытие, которое отменили новым показом, ничего не скрывает.
    private(set) var presentation = 0

    var isVisible: Bool { panel?.isVisible == true && !isLeaving }
    var monitorsInstalled: Bool { keyMonitor != nil }

    func toggle(controller: ClipboardController) {
        isVisible ? hide() : show(controller: controller)
    }

    func show(controller: ClipboardController) {
        let model = self.model ?? makeModel(controller)
        model.allItems = controller.items
        model.spaces = controller.spaces
        model.storeError = controller.storeError
        model.limit = controller.limit
        present(model)
    }

    /// Показать панель с готовой моделью. Панель одна на модель: другую модель сюда не подставляют.
    @discardableResult
    func present(_ model: ClipboardPanelModel) -> NSPanel {
        self.model = model
        model.reset()
        model.refreshTheme()

        let panel = self.panel ?? panelMaker(model)
        self.panel = panel
        model.pointer = { [weak panel] in panel.map { Self.pointInPanel(NSEvent.mouseLocation, frame: $0.frame) } }
        let frame = standFrame ?? Self.frameOnCursorScreen()
        // Открыли посреди ухода на том же экране: панель едет обратно с того места, где она сейчас, без скачка.
        let resuming = isLeaving && frame == shownFrame
        presentation += 1
        isLeaving = false
        // Панель никуда не ушла, значит ждать нечего. ⌘V теперь попал бы в неё саму.
        leftCallbacks = []
        shownFrame = frame
        panel.ignoresMouseEvents = false
        if !resuming {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -Self.slideDistance), display: false)
            panel.alphaValue = 0
        }
        // Раскладка новых данных здесь, а не посреди движения: иначе первый шаг анимации опаздывает и окно прыгает.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        // Первый показ рисуется долго: пусть это случится при нулевой альфе, отсчёт движения начнётся после.
        panel.displayIfNeeded()
        let duration = showDuration
        if duration == 0 {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
        } else {
            // В следующем такте: отсчёт анимации идёт от начала текущего, и всё, что сделано выше (30–80 мс), она считала бы прошедшим.
            // На ленте окно появлялось уже на 90% пути.
            let presentation = self.presentation
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.presentation == presentation, !self.isLeaving else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = duration
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        // Окно только едет: размер тот же, перерисовка и раскладка не нужны.
                        panel.animator().setFrame(frame, display: false)
                        panel.animator().alphaValue = 1
                    }
                }
            }
        }
        installMonitors()
        return panel
    }

    /// Точка экрана в координатах панели: от её левого верхнего угла, как у видов внутри.
    static func pointInPanel(_ screen: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)
    }

    /// Экран, где сейчас курсор; панель во всю его ширину над Dock.
    private static func frameOnCursorScreen() -> CGRect {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen?.frame.minX ?? 0, y: area.minY,
                      width: screen?.frame.width ?? area.width, height: height)
    }

    /// Закрытие, зеркальное показу. `left` зовётся один раз, когда окна уже нет на экране.
    /// Если панель открыли снова раньше, `left` не зовётся совсем: уход не состоялся.
    func hide(then left: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else {
            left?()
            return
        }
        model?.panelClosing()
        if let left { leftCallbacks.append(left) }
        guard !isLeaving else { return }
        isLeaving = true
        removeMonitors()
        // Второй клик по уезжающей карточке не должен вставить ещё раз. Клики за это время достаются программе под панелью.
        panel.ignoresMouseEvents = true
        let duration = hideDuration
        if duration == 0 {
            finishLeaving(panel)
            return
        }
        let presentation = self.presentation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(shownFrame.offsetBy(dx: 0, dy: -Self.slideDistance), display: false)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLeaving, self.presentation == presentation else { return }
                self.finishLeaving(panel)
            }
        }
    }

    private func finishLeaving(_ panel: NSPanel) {
        isLeaving = false
        panel.orderOut(nil)
        panel.alphaValue = 0
        // Расшифрованным картинкам незачем лежать в памяти, пока панели нет.
        model?.forgetImages()
        let callbacks = leftCallbacks
        leftCallbacks = []
        callbacks.forEach { $0() }
    }

    /// Панель держит копию данных; пока открыта, новые записи в ней не нужны.
    func makeModel(_ controller: ClipboardController) -> ClipboardPanelModel {
        let model = ClipboardPanelModel()
        self.model = model
        model.imageLoader = { [weak controller] item in controller?.imageData(item).flatMap { NSImage(data: $0) } }
        model.imageBytes = { [weak controller] item in
            // Запрос придёт не обязательно на главном потоке. Хранилищу это не мешает: чтение файла и ключ неизменяемы.
            nonisolated(unsafe) let store = controller?.store
            return { store?.imageData(item) }
        }
        model.onPaste = { [weak controller] item in controller?.paste(item) }
        model.onPasteMany = { [weak controller] items in controller?.pasteMany(items) }
        model.onPin = { [weak self, weak controller] id, space in
            controller?.pin(id, to: space)
            self?.refresh(controller)
        }
        model.onDelete = { [weak self, weak controller] id in
            controller?.delete(id)
            self?.refresh(controller)
        }
        model.onAddSpace = { [weak self, weak controller] name, color, hidden in
            controller?.addSpace(name: name, colorID: color, hidesContent: hidden)
            self?.refresh(controller)
        }
        model.onRenameSpace = { [weak self, weak controller] id, name in
            controller?.renameSpace(id, to: name)
            self?.refresh(controller)
        }
        model.onSetSpaceColor = { [weak self, weak controller] id, color in
            controller?.setColor(id, color)
            self?.refresh(controller)
        }
        model.onSetTitle = { [weak self, weak controller] id, title in
            controller?.setTitle(id, title)
            self?.refresh(controller)
        }
        model.onMoveRecord = { [weak self, weak controller] id, position in
            controller?.moveRecord(id, to: position)
            self?.refresh(controller)
        }
        model.onMoveSpace = { [weak self, weak controller] id, position in
            controller?.moveSpace(id, to: position)
            self?.refresh(controller)
        }
        model.onSetSpaceHidden = { [weak self, weak controller] id, hidden in
            controller?.setSpaceHidden(id, hidden)
            self?.refresh(controller)
        }
        model.onDeleteSpace = { [weak self, weak controller] id in
            controller?.deleteSpace(id)
            self?.refresh(controller)
        }
        model.onClose = { [weak self] in self?.hide() }
        if let opener = settingsOpener {
            model.onOpenSettings = { [weak self] in
                // Окно настроек активирует утилиту: панель уходит раньше.
                self?.hide()
                opener()
            }
        }
        return model
    }

    private func refresh(_ controller: ClipboardController?) {
        guard let controller, let model else { return }
        model.allItems = controller.items
        model.spaces = controller.spaces
        model.selected = min(model.selected, max(0, model.visible.count - 1))
    }

    static func makePanel(_ model: ClipboardPanelModel) -> NSPanel {
        let panel = ClipboardNSPanel(contentRect: CGRect(x: 0, y: 0, width: 1200, height: Self.height),
                                     styleMask: [.nonactivatingPanel, .borderless],
                                     backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // Панель показывает содержимое буфера открытым текстом: при показе экрана её не видно.
        panel.sharingType = .none

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 22
        glass.layer?.cornerCurve = .continuous
        glass.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        glass.layer?.masksToBounds = true

        let host = ClipPanelHostingView.make(ClipboardPanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
        return panel
    }

    // MARK: Клавиши и клики

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        // Клик мимо поля названия сохраняет правку, куда бы он ни пришёлся. Само событие идёт дальше.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.saveInlineEdit(clickedBy: event) }
            return event
        }
        guard hidesOnOutsideClick else { return }
        // Клик в другой программе (или на рабочем столе) закрывает панель.
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        keyMonitor = nil
        mouseMonitor = nil
        globalClick = nil
        activation = nil
    }

    private func saveInlineEdit(clickedBy event: NSEvent) {
        guard let model, model.isEditingInline, let panel, event.window === panel else { return }
        // Клик в самом поле: двигает курсор, правка идёт дальше. Пока поле в фокусе, его текст показывает редактор окна, он и есть первый ответчик.
        if let hit = panel.contentView?.hitTest(event.locationInWindow), let editor = panel.firstResponder as? NSView,
           hit === editor || (hit is NSTextField && editor.isDescendant(of: hit)) { return }
        model.commitInlineEdit()
    }

    /// Возвращает nil, если клавишу забрала панель; иначе событие уходит в поле, где стоит курсор.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let panel, panel.isVisible, event.window === panel else { return event }
        // Пока идёт набор через IME, стрелки и Enter принадлежат ему.
        if let field = panel.firstResponder as? NSTextView, field.hasMarkedText() { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = ClipPanelKey(code: event.keyCode, command: flags.contains(.command), control: flags.contains(.control),
                               shift: flags.contains(.shift),
                               text: flags.contains(.command) ? event.charactersIgnoringModifiers : event.characters)
        if model.handleKey(key) { return nil }
        // Поле поиска потеряло фокус (клик мог его забрать): буква всё равно должна начать поиск, а не пропасть.
        if !model.isEditingInline, !(panel.firstResponder is NSTextView), key.isPlainText, let text = key.text {
            model.typeIntoSearch(text)
            return nil
        }
        return event
    }
}
