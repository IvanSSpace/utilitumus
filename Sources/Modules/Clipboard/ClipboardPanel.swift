import SwiftUI
import AppKit

/// Палитра пространств: в хранилище лежит только id.
enum ClipPalette {
    static let all: [(id: String, name: String, color: Color)] = [
        ("blue", "Синий", Color(red: 0.30, green: 0.55, blue: 1.0)),
        ("teal", "Бирюзовый", Color(red: 0.20, green: 0.78, blue: 0.78)),
        ("green", "Зелёный", Color(red: 0.30, green: 0.80, blue: 0.45)),
        ("yellow", "Жёлтый", Color(red: 0.98, green: 0.78, blue: 0.25)),
        ("orange", "Оранжевый", Color(red: 1.0, green: 0.55, blue: 0.22)),
        ("red", "Красный", Color(red: 0.97, green: 0.35, blue: 0.38)),
        ("pink", "Розовый", Color(red: 0.96, green: 0.45, blue: 0.70)),
        ("purple", "Фиолетовый", Color(red: 0.68, green: 0.48, blue: 0.98)),
        ("gray", "Серый", Color(red: 0.62, green: 0.64, blue: 0.70)),
    ]

    static func color(_ id: String) -> Color { all.first { $0.id == id }?.color ?? all[0].color }
    static func nextID(after count: Int) -> String { all[count % all.count].id }
}

/// «5 мин назад», «вчера».
func clipAgo(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "только что" }
    if s < 3600 { return "\(s / 60) мин назад" }
    if s < 86400 { return "\(s / 3600) ч назад" }
    if s < 2 * 86400 { return "вчера" }
    return "\(s / 86400) дн. назад"
}

/// Иконки программ-источников: по bundle id, чтобы не перерисовывать на каждый кадр.
@MainActor
enum ClipSourceIcon {
    private static var cache: [String: NSImage] = [:]
    private static var large: [String: NSImage] = [:]

    static func image(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = icon
        return icon
    }

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

/// Окошко категории в самой панели. Не NSPopover: его окно не из неактивирующих, клик в нём мог бы активировать
/// утилиту и забрать фокус у программы, куда потом вставляем.
struct ClipSpaceEditor: Equatable {
    enum Mode: Equatable {
        case create
        case edit(UUID)
        case confirmDelete(UUID)
    }

    var mode: Mode
    var name = ""
    var colorID = ClipPalette.all[0].id

    var cleanName: String? { ClipboardWireRules.cleanName(name) }
}

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var allItems: [ClipItem] = []
    @Published var spaces: [ClipSpace] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selected = 0
            clicks.reset()
            scrollRequest = visible.first?.id
            // Буква ушла в скрытое поле: поиск раскрывается сам. Стёртый текст поиск не закрывает, это делает Esc.
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
    @Published private(set) var scrollRequest: UUID?
    /// Вернуть фокус в поле поиска.
    @Published private(set) var focusRequest = 0
    /// Лимит истории: для честной подписи при удалении пространства.
    var limit = ClipboardPolicy.defaultLimit

    var imageLoader: (ClipItem) -> NSImage? = { _ in nil }
    var onPaste: (ClipItem) -> Void = { _ in }
    var onPin: (UUID, UUID?) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onAddSpace: (String, String) -> Void = { _, _ in }
    var onRenameSpace: (UUID, String) -> Void = { _, _ in }
    var onSetSpaceColor: (UUID, String) -> Void = { _, _ in }
    var onDeleteSpace: (UUID) -> Void = { _ in }
    /// nil — открыть настройки неоткуда, пункта в меню нет.
    var onOpenSettings: (() -> Void)?

    private var clicks = ClipClickTracker()
    private let images = NSCache<NSUUID, NSImage>()

    init() { images.countLimit = 24 }

    /// В «Истории» видно всё, что есть; во вкладке пространства — только его записи.
    var visible: [ClipItem] { ClipboardStore.filter(allItems, space: tab, query: query) }

    var selectedItem: ClipItem? {
        let list = visible
        return list.indices.contains(selected) ? list[selected] : nil
    }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        selected = min(max(selected + delta, 0), list.count - 1)
        scrollRequest = list[selected].id
    }

    func quickPick(_ number: Int) {
        let list = visible
        guard list.indices.contains(number - 1) else { return }
        onPaste(list[number - 1])
    }

    func selectTab(_ id: UUID?) {
        tab = id
        selected = 0
        clicks.reset()
        scrollRequest = visible.first?.id
    }

    func cycleTab(_ delta: Int) {
        let ids: [UUID?] = [nil] + spaces.map { Optional($0.id) }
        let current = ids.firstIndex(of: tab) ?? 0
        selectTab(ids[(current + delta + ids.count) % ids.count])
    }

    /// Клик по карточке: выделение сразу, вставка только вторым кликом в пределах окна.
    func click(_ item: ClipItem, at index: Int, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        selected = index
        if clicks.click(item.id, at: time) == .paste { onPaste(item) }
    }

    func reset() {
        query = ""
        searchOpen = false
        tab = nil
        selected = 0
        editor = nil
        clicks.reset()
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
                if case .confirmDelete = editor.mode { return true }
                return false
            }
        }
        if key.command, let digit = key.digit, (1...9).contains(digit) {
            quickPick(digit)
            return true
        }
        switch key.code {
        case 123: move(-1); return true               // ←
        case 124: move(1); return true                // →
        case 36, 76:                                  // Enter
            if let item = selectedItem { onPaste(item) }
            return true
        case 53:                                      // Esc
            if searchOpen { closeSearch() } else { onClose() }
            return true
        case 48: cycleTab(key.shift ? -1 : 1); return true  // Tab
        case 51 where key.command:                    // ⌘⌫ — удалить запись
            if let item = selectedItem { onDelete(item.id) }
            return true
        default:
            // Поиск закрыт: в скрытое поле идут только буквы, раскрывающие его. Пробел, стрелки и Delete там незачем.
            if !searchOpen, !key.command, !key.isPlainText { return true }
            return false
        }
    }

    // MARK: Пространства

    var canAddSpace: Bool { spaces.count < ClipboardWireRules.maxSpaces }

    func beginCreate() {
        guard canAddSpace else { return }
        editor = ClipSpaceEditor(mode: .create, colorID: ClipPalette.nextID(after: spaces.count))
    }

    func beginEdit(_ space: ClipSpace) {
        editor = ClipSpaceEditor(mode: .edit(space.id), name: space.name, colorID: space.colorID)
    }

    func beginDelete(_ space: ClipSpace) {
        editor = ClipSpaceEditor(mode: .confirmDelete(space.id), name: space.name, colorID: space.colorID)
    }

    func closeEditor() {
        editor = nil
        focusRequest += 1
    }

    /// Создать или сохранить. Пустое имя не принимается, окошко остаётся открытым.
    /// Удаление здесь не идёт: Enter не должен подтверждать его случайно, только кнопка `confirmDelete`.
    func commitEditor() {
        guard let editor, let name = editor.cleanName else { return }
        switch editor.mode {
        case .create:
            guard canAddSpace else { return }
            onAddSpace(name, editor.colorID)
        case .edit(let id):
            guard let space = spaces.first(where: { $0.id == id }) else { break }
            if space.name != name { onRenameSpace(id, name) }
            if space.colorID != editor.colorID { onSetSpaceColor(id, editor.colorID) }
        case .confirmDelete:
            return
        }
        closeEditor()
    }

    func confirmDelete() {
        guard case .confirmDelete(let id)? = editor?.mode else { return }
        onDeleteSpace(id)
        if tab == id { selectTab(nil) }
        closeEditor()
    }
}

// MARK: - Вид панели

/// Высоты панели: окно задаёт высоту, карточка получает всё, что осталось под верхним рядом.
enum ClipPanelMetrics {
    static let panelHeight: CGFloat = 350
    static let topPadding: CGFloat = 12
    static let barHeight: CGFloat = 36
    static let barGap: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    /// Запас вокруг карточки под рамку выбора.
    static let ringRoom: CGFloat = 6
    static let cardHeight = panelHeight - topPadding - barHeight - barGap - bottomPadding - ringRoom * 2
    static let searchWidth: CGFloat = 440
}

private struct ClipAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
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
    private static let plusAnchor = "plus"

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
        .onPreferenceChange(ClipAnchorKey.self) { anchors = $0 }
        .environment(\.colorScheme, .dark)
        .onAppear { focusSearch() }
        .onChange(of: model.focusRequest) { focusSearch() }
    }

    /// Поле поиска живёт всегда, только скрыто, и держит клавиатуру: буква сразу попадает в него со всей раскладкой и IME.
    /// Курсор в конец: при получении фокуса поле выделяет весь текст, и следующая буква стёрла бы предыдущую.
    private func focusSearch() {
        guard model.editor == nil else { return }
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: model.searchOpen ? 10 : 6) {
                        searchField
                        historyTab
                        ForEach(model.spaces) { space in
                            if model.searchOpen { spaceDot(space) } else { spaceTab(space) }
                        }
                        if !model.searchOpen { plusButton }
                    }
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
            moreMenu
        }
        .frame(height: ClipPanelMetrics.barHeight)
        .animation(.easeOut(duration: 0.14), value: model.searchOpen)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { model.openSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: model.searchOpen ? 14 : 16, weight: .regular))
                    .foregroundStyle(ink.opacity(model.searchOpen ? 0.7 : 0.8))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .help("Буфер обмена")
    }

    private func spaceTab(_ space: ClipSpace) -> some View {
        let active = model.tab == space.id
        return Button { model.selectTab(space.id) } label: {
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
        .buttonStyle(.plain)
        .clipAnchor(space.id.uuidString)
        .contextMenu { spaceMenu(space) }
        .onDrop(of: [.plainText], isTargeted: nil) { dropCard($0, on: space.id) }
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
        .buttonStyle(.plain)
        .help(space.name)
        .accessibilityLabel(space.name)
        .clipAnchor(space.id.uuidString)
        .contextMenu { spaceMenu(space) }
        .onDrop(of: [.plainText], isTargeted: nil) { dropCard($0, on: space.id) }
    }

    /// Перетащил карточку на категорию — запись закрепилась в ней.
    private func dropCard(_ providers: [NSItemProvider], on space: UUID) -> Bool {
        providers.first?.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let item = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { model.onPin(item, space) }
        }
        return true
    }

    @ViewBuilder private func spaceMenu(_ space: ClipSpace) -> some View {
        Button("Переименовать") { model.beginEdit(space) }
        Button("Сменить цвет") { model.beginEdit(space) }
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
        .buttonStyle(.plain)
        .disabled(!model.canAddSpace)
        .help("Новое пространство")
        .clipAnchor(Self.plusAnchor)
    }

    private var moreMenu: some View {
        Menu {
            if let open = model.onOpenSettings {
                Button("Настройки Буфера…", action: open)
                Divider()
            }
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
        .fixedSize()
        .help("Подсказки и настройки")
    }

    // MARK: Окошко категории

    private var editorLayer: some View {
        GeometryReader { geometry in
            let width: CGFloat = 300
            let anchor = editorAnchor
            let x = min(max(anchor.midX, width / 2 + 12), geometry.size.width - width / 2 - 12)
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
        default: return anchors[Self.plusAnchor] ?? fallback
        }
    }

    // MARK: Лента карточек

    private var cards: some View {
        let list = model.visible
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
                        LazyHStack(spacing: 16) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, number: index < 9 ? index + 1 : nil,
                                         selected: index == model.selected, searching: model.searchOpen,
                                         theme: model.theme, spaces: model.spaces, model: model)
                                    .id(item.id)
                                    // Один обработчик: второй, на двойной клик, заставил бы одиночный ждать.
                                    .onTapGesture { model.click(item, at: index) }
                            }
                        }
                        .padding(.horizontal, ClipPanelMetrics.ringRoom).padding(.vertical, ClipPanelMetrics.ringRoom)
                    }
                    .onChange(of: model.scrollRequest) {
                        guard let target = model.scrollRequest else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .confirmDelete(let id)? = model.editor?.mode {
                confirmation(id)
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

    private var isCreating: Bool { model.editor?.mode == .create }

    @ViewBuilder private var form: some View {
        TextField("Название", text: Binding(get: { model.editor?.name ?? "" }, set: { model.editor?.name = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($nameFocused)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.09)))
            .onAppear { nameFocused = true }
        HStack(spacing: 6) {
            ForEach(ClipPalette.all, id: \.id) { entry in
                let chosen = entry.id == model.editor?.colorID
                Button { model.editor?.colorID = entry.id } label: {
                    Circle().fill(entry.color).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(.white.opacity(chosen ? 0.95 : 0.15), lineWidth: chosen ? 2 : 1))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
            }
        }
        HStack {
            Spacer()
            actionButton("Отмена", prominent: false) { model.closeEditor() }
            actionButton(isCreating ? "Создать" : "Сохранить", prominent: true) { model.commitEditor() }
                .disabled(model.editor?.cleanName == nil)
                .opacity(model.editor?.cleanName == nil ? 0.45 : 1)
        }
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
        .buttonStyle(.plain)
    }
}

// MARK: - Окно панели

/// Панель, которая берёт клавиатуру, но не делает Utilitumus активным: впереди остаётся та программа,
/// куда потом вставляем.
private final class ClipboardNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelHost {
    static let shared = ClipboardPanelHost()
    static let height = ClipPanelMetrics.panelHeight

    /// Утилита открывает своё окно настроек; у встроенного модуля пути нет, и пункта в меню тоже.
    var settingsOpener: (() -> Void)?
    /// false — только для показа автору: панель не закрывается от кликов мимо и смены программы.
    var hidesOnOutsideClick = true

    private var panel: NSPanel?
    private var model: ClipboardPanelModel?
    private var keyMonitor: Any?
    private var globalClick: Any?
    private var activation: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }

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

        let panel = self.panel ?? Self.makePanel(model)
        self.panel = panel
        // Экран, где сейчас курсор; панель во всю его ширину над Dock.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: screen?.frame.minX ?? 0, y: area.minY,
                           width: screen?.frame.width ?? area.width, height: Self.height)
        panel.setFrame(frame.offsetBy(dx: 0, dy: -40), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        installMonitors()
        return panel
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        panel.alphaValue = 0
        // Расшифрованным картинкам незачем лежать в памяти, пока панели нет.
        model?.forgetImages()
    }

    /// Панель держит копию данных; пока открыта, новые записи в ней не нужны.
    func makeModel(_ controller: ClipboardController) -> ClipboardPanelModel {
        let model = ClipboardPanelModel()
        self.model = model
        model.imageLoader = { [weak controller] item in controller?.imageData(item).flatMap { NSImage(data: $0) } }
        model.onPaste = { [weak controller] item in controller?.paste(item) }
        model.onPin = { [weak self, weak controller] id, space in
            controller?.pin(id, to: space)
            self?.refresh(controller)
        }
        model.onDelete = { [weak self, weak controller] id in
            controller?.delete(id)
            self?.refresh(controller)
        }
        model.onAddSpace = { [weak self, weak controller] name, color in
            controller?.addSpace(name: name, colorID: color)
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

        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
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
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        keyMonitor = nil
        globalClick = nil
        activation = nil
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
        if !(panel.firstResponder is NSTextView), key.isPlainText, let text = key.text {
            model.typeIntoSearch(text)
            return nil
        }
        return event
    }
}
