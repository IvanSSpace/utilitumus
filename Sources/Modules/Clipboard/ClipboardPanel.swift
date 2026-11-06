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

    static func image(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - Модель панели

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var allItems: [ClipItem] = []
    @Published var spaces: [ClipSpace] = []
    @Published var query = ""
    /// nil — вкладка «История».
    @Published var tab: UUID?
    @Published var selected = 0
    /// Истории нет из-за ошибки хранилища: вместо «История пуста» говорим об этом.
    @Published var storeError: String?

    var imageLoader: (ClipItem) -> NSImage? = { _ in nil }
    var onPaste: (ClipItem) -> Void = { _ in }
    var onPin: (UUID, UUID?) -> Void = { _, _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onClose: () -> Void = {}

    /// В «Истории» видно всё, что есть; во вкладке пространства — только его записи.
    var visible: [ClipItem] { ClipboardStore.filter(allItems, space: tab, query: query) }

    var selectedItem: ClipItem? {
        let list = visible
        return list.indices.contains(selected) ? list[selected] : nil
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selected = min(max(selected + delta, 0), count - 1)
    }

    func quickPick(_ number: Int) {
        let list = visible
        guard list.indices.contains(number - 1) else { return }
        onPaste(list[number - 1])
    }

    func cycleTab(_ delta: Int) {
        let ids: [UUID?] = [nil] + spaces.map { Optional($0.id) }
        let current = ids.firstIndex(of: tab) ?? 0
        tab = ids[(current + delta + ids.count) % ids.count]
        selected = 0
    }

    func reset() {
        query = ""
        tab = nil
        selected = 0
    }
}

// MARK: - Вид панели

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    private let ink = Color.white

    var body: some View {
        VStack(spacing: 14) {
            topBar
            cards
            hints
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { model.selected = 0 }
    }

    // MARK: Верх: поиск и вкладки

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.45))
                TextField("Поиск", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12).frame(width: 230, height: 32)
            .background(Capsule().fill(ink.opacity(0.09)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tabButton(title: "История", color: nil, id: nil)
                    ForEach(model.spaces) { space in
                        tabButton(title: space.name, color: ClipPalette.color(space.colorID), id: space.id)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tabButton(title: String, color: Color?, id: UUID?) -> some View {
        let active = model.tab == id
        return Button {
            model.tab = id
            model.selected = 0
        } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 9, height: 9) }
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(ink.opacity(active ? 1 : 0.6))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(ink.opacity(active ? 0.16 : 0.0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Перетащил карточку на вкладку — запись закрепилась в этом пространстве.
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let id else { return false }
            providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, let item = UUID(uuidString: text) else { return }
                DispatchQueue.main.async { model.onPin(item, id) }
            }
            return true
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
                        LazyHStack(spacing: 12) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, number: index < 9 ? index + 1 : nil,
                                         selected: index == model.selected, model: model)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { model.onPaste(item) }
                                    .onTapGesture { model.selected = index }
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 6)
                    }
                    .onChange(of: model.selected) {
                        if list.indices.contains(model.selected) {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(list[model.selected].id, anchor: .center) }
                        }
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

    private var hints: some View {
        HStack(spacing: 16) {
            hint("←→", "выбор")
            hint("⏎", "вставить")
            hint("⌘1–9", "быстро")
            hint("⇥", "вкладка")
            hint("Esc", "закрыть")
            Spacer()
            Text("Правый клик — в пространство").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35))
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ink.opacity(0.12)))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(ink.opacity(0.5))
    }
}

// MARK: - Карточка

private struct ClipCard: View {
    let item: ClipItem
    let number: Int?
    let selected: Bool
    @ObservedObject var model: ClipboardPanelModel

    static let width: CGFloat = 206

    private var tint: Color {
        switch item.kind {
        case .text: return Color(red: 0.42, green: 0.52, blue: 0.95)
        case .link: return Color(red: 0.20, green: 0.68, blue: 0.80)
        case .image: return Color(red: 0.32, green: 0.72, blue: 0.48)
        case .file: return Color(red: 0.92, green: 0.58, blue: 0.25)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.9) : Color.white.opacity(0.07), lineWidth: selected ? 2 : 1))
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .contextMenu { menu }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.title).font(.system(size: 13, weight: .bold))
                Text(clipAgo(item.date)).font(.system(size: 10.5)).opacity(0.8)
            }
            Spacer(minLength: 4)
            if let space = model.spaces.first(where: { $0.id == item.spaceID }) {
                Circle().fill(ClipPalette.color(space.colorID)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .help("Пространство «\(space.name)»")
            }
            if let icon = ClipSourceIcon.image(item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 18)).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text:
            Text(String((item.text ?? "").prefix(400)))
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                .lineLimit(9).multilineTextAlignment(.leading)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "link").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.18)))
                Text(item.host ?? item.text ?? "").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(item.text ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(4).multilineTextAlignment(.leading)
            }
        case .image:
            if let image = model.imageLoader(item) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: Self.width - 24, height: 120, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
            }
        case .file:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((item.filePaths ?? []).prefix(4)), id: \.self) { path in
                    HStack(spacing: 7) {
                        Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(tint)
                        Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            Spacer()
            if let number {
                Text("⌘\(number)").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 9)
    }

    private var caption: String {
        switch item.kind {
        case .text: return "\((item.text ?? "").count) симв."
        case .link: return item.host ?? "ссылка"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight { return "\(w)×\(h)" }
            return "картинка"
        case .file:
            let n = item.filePaths?.count ?? 0
            return n == 1 ? "1 файл" : "\(n) файлов"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Вставить") { model.onPaste(item) }
        Menu("В пространство") {
            ForEach(model.spaces) { space in
                Button(space.name) { model.onPin(item.id, space.id) }
            }
            if model.spaces.isEmpty { Text("Пространств нет — создай в «Буфере»") }
        }
        if item.spaceID != nil {
            Button("Убрать из пространства") { model.onPin(item.id, nil) }
        }
        Divider()
        Button("Удалить", role: .destructive) { model.onDelete(item.id) }
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
    static let height: CGFloat = 350

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
        self.model = model
        model.allItems = controller.items
        model.spaces = controller.spaces
        model.storeError = controller.storeError
        model.reset()

        let panel = self.panel ?? makePanel(model)
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
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    /// Панель держит копию данных; пока открыта, новые записи в ней не нужны.
    private func makeModel(_ controller: ClipboardController) -> ClipboardPanelModel {
        let model = ClipboardPanelModel()
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
        model.onClose = { [weak self] in self?.hide() }
        return model
    }

    private func refresh(_ controller: ClipboardController?) {
        guard let controller, let model else { return }
        model.allItems = controller.items
        model.spaces = controller.spaces
        model.selected = min(model.selected, max(0, model.visible.count - 1))
    }

    private func makePanel(_ model: ClipboardPanelModel) -> NSPanel {
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

    /// Возвращает nil, если клавишу забрала панель; иначе событие уходит в поле поиска.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let panel, panel.isVisible, event.window === panel else { return event }
        // Пока идёт набор через IME, стрелки и Enter принадлежат ему.
        if let field = panel.firstResponder as? NSTextView, field.hasMarkedText() { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            model.quickPick(digit)
            return nil
        }
        switch event.keyCode {
        case 123: model.move(-1); return nil          // ←
        case 124: model.move(1); return nil           // →
        case 36, 76:                                  // Enter
            if let item = model.selectedItem { model.onPaste(item) }
            return nil
        case 53: hide(); return nil                   // Esc
        case 48: model.cycleTab(flags.contains(.shift) ? -1 : 1); return nil  // Tab
        case 51 where flags.contains(.command):       // ⌘⌫ — удалить запись
            if let item = model.selectedItem { model.onDelete(item.id) }
            return nil
        default: return event
        }
    }
}
