import SwiftUI

// Каркас окна: фон, боковая панель. Экранам модулей это не нужно — только для `MainView`.

// MARK: - Фон

/// Статичный градиент оттенка модуля. При смене модуля — кроссфейд 0.3 с (без пятен и таймеров).
struct DSBackground: View {
    let module: Module
    @Environment(\.dsTheme) private var theme

    var body: some View {
        ZStack {
            Color(white: 0.05)
            if theme.followsModule {
                ForEach(Module.allCases) { m in
                    gradient(m).opacity(m == module ? 1 : 0)
                }
            } else {
                gradient(module)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: module)
    }

    private func gradient(_ m: Module) -> some View {
        LinearGradient(colors: theme.background(m), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension DSTheme {
    /// Меняется ли фон от модуля к модулю (иначе кроссфейд не нужен).
    var followsModule: Bool { self == .calm || self == .vivid }
}

// MARK: - Боковая панель

struct DSSidebar: View {
    let current: Module?
    @Binding var showAbout: Bool
    @Binding var peeked: Module?
    @Binding var selection: Module
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Место под светофоры и кнопку скрытия панели.
            Spacer().frame(height: 46)
            List {
                ForEach(ModuleCategory.all) { category in
                    let items = modules.shownModules.filter { $0.category == category }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { module in row(module) }
                                .onMove { move(items, from: $0, to: $1) }
                        } header: {
                            DSCategoryHeader(category: category)
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            DSSidebarFooter(showAbout: $showAbout, peeked: $peeked)
        }
    }

    private func row(_ module: Module) -> some View {
        DSSidebarRow(module: module, on: modules.isOn(module),
                     selected: !showAbout && peeked == nil && current == module) {
            selection = module
            peeked = nil
            showAbout = false
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            let on = modules.isOn(module)
            Button(on ? "Выключить модуль" : "Включить модуль") { modules.setOn(module, !on) }
            Button("Скрыть из панели") { modules.setHidden(module, true) }
            Divider()
            Button("Настроить модули…") { modules.settingsShown = true }
        }
    }

    /// Перетаскивание только внутри категории: индексы категории переводим в индексы общего списка панели.
    private func move(_ items: [Module], from source: IndexSet, to destination: Int) {
        let shown = modules.shownModules
        let global = items.compactMap { shown.firstIndex(of: $0) }
        let to = destination < global.count ? global[destination] : (global.last ?? 0) + 1
        modules.moveShown(from: IndexSet(source.map { global[$0] }), to: to)
    }
}

/// Заголовок категории: полоска её цвета и название капсом; подзаголовок — во всплывающей подсказке.
private struct DSCategoryHeader: View {
    let category: ModuleCategory
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(theme.categoryColor(category)).frame(width: 3, height: 12)
            Text(category.title.uppercased())
                .font(DS.sectionTitle).tracking(0.8)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16).padding(.top, 8).padding(.bottom, 2)
        .help(category.subtitle)
    }
}

// MARK: - Скрытие панели

extension DS {
    /// Ключ `@AppStorage`: скрыта ли боковая панель.
    static let sidebarHiddenKey = "Design.SidebarHidden"
    static let sidebarAnimation = Animation.easeInOut(duration: 0.2)
}

/// Кнопка скрытия/показа панели рядом со светофорами. Остаётся видна и при скрытой панели.
/// Положение берём у настоящей кнопки «зелёный» окна, чтобы не гадать с отступами системы.
struct DSSidebarToggle: View {
    @Binding var hidden: Bool
    @State private var anchor = CGPoint(x: 86, y: 20)
    @State private var hover = false

    var body: some View {
        Button { withAnimation(DS.sidebarAnimation) { hidden.toggle() } } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.65))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? .white.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(hidden ? "Показать боковую панель (⌃⌘S)" : "Скрыть боковую панель (⌃⌘S)")
        .position(x: anchor.x + 14, y: anchor.y)
        .background(TrafficLightProbe(anchor: $anchor))
    }
}

/// Читает положение кнопки «zoom» окна: справа от неё ставим переключатель панели.
private struct TrafficLightProbe: NSViewRepresentable {
    @Binding var anchor: CGPoint

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { point in
            if point != anchor { DispatchQueue.main.async { anchor = point } }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((CGPoint) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(measure), name: name, object: window)
            }
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        @objc private func measure() {
            guard let window, let zoom = window.standardWindowButton(.zoomButton),
                  let superview = zoom.superview, let content = window.contentView else { return }
            let frame = superview.convert(zoom.frame, to: content)
            // Координаты содержимого — от нижнего края; SwiftUI считает от верхнего.
            let y = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
            guard frame.maxX > 0, y > 0 else { return }
            onChange?(CGPoint(x: frame.maxX + 8, y: y))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Строка модуля: значок, название, справа точка «включён» или «выкл». Выбранная залита оттенком.
private struct DSSidebarRow: View {
    let module: Module
    let on: Bool
    let selected: Bool
    let action: () -> Void
    @Environment(\.dsTheme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 24).opacity(on ? 1 : 0.45)
            Text(module.title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(on ? (selected ? 1 : 0.85) : 0.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            if on {
                Circle().fill(theme.tone(module)).frame(width: 6, height: 6)
            } else {
                Text("выкл").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
            .fill(selected ? theme.selection(module) : (hover ? .white.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .help(on ? "" : "Выключен — открой, чтобы включить")
        .accessibilityAddTraits(.isButton)
    }
}

/// Внизу панели: обновление, «Скрытые», «Что нового», «Настроить модули», «О проекте», версия.
struct DSSidebarFooter: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var modules = ModuleManager.shared
    @Binding var showAbout: Bool
    @Binding var peeked: Module?
    /// Свёрнутость списка помним между запусками: скрытые открывают редко, но привычка остаётся.
    @AppStorage("HiddenModulesExpanded") private var hiddenExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch updater.state {
            case let .available(version, _, _):
                DSButton("Обновить до \(version)", icon: "arrow.down.circle.fill", style: .primary, small: true) {
                    updater.install()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Устанавливаю…").font(.caption)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            case .upToDate:
                Text("Обновлений нет")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10).padding(.bottom, 4)
            default:
                EmptyView()
            }
            hiddenSection
            FooterLink(icon: "sparkles", title: "Что нового") { WhatsNew.shared.isShown = true }
            // Порядок, скрытие и выключение модулей — в Настройках; без этой строки туда попадали только через Cmd+, или контекстное меню.
            FooterLink(icon: "slider.horizontal.3", title: "Настроить модули") { modules.settingsShown = true }
            FooterLink(icon: "info.circle", title: "О проекте", selected: showAbout) { showAbout = true }
            HStack {
                // Клик по версии — «Обновление стороннего программного обеспечения»: что нового.
                Button("Версия \(updater.currentVersion)") { WhatsNew.shared.isShown = true }
                    .buttonStyle(.plain)
                    .help("Что изменилось в последних версиях")
                Spacer()
                Button {
                    updater.check()
                } label: {
                    if updater.state == .checking {
                        ProgressView().controlSize(.mini)
                    } else if updater.state == .upToDate {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .help(updater.state == .upToDate ? "Установлена последняя версия" : "Проверить обновления")
                .disabled(updater.state == .checking || updater.state == .installing)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 10).padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// «Скрытые · N» над «Что нового»: без скрытых модулей строки нет совсем.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = modules.hiddenModules
        if !hidden.isEmpty {
            FooterLink(icon: "eye.slash", title: "Скрытые · \(hidden.count)", dim: true,
                       chevron: hiddenExpanded) { hiddenExpanded.toggle() }
            if hiddenExpanded {
                ForEach(hidden) { module in
                    HiddenRow(module: module, selected: peeked == module && !showAbout) {
                        // Разовый показ: состояние не меняем, выделение в основном списке снимается через peeked.
                        peeked = module
                        showAbout = false
                    }
                    .contextMenu {
                        Button("Показать в панели") { modules.setHidden(module, false) }
                        Button(modules.isOn(module) ? "Выключить модуль" : "Включить модуль") {
                            modules.setOn(module, !modules.isOn(module))
                        }
                    }
                }
            }
        }
    }
}

/// Пункт внизу панели: значок и подпись, подсветка при наведении.
private struct FooterLink: View {
    let icon: String
    let title: String
    var selected = false
    var dim = false
    /// nil — шеврона нет; true/false — раскрыто/свёрнуто.
    var chevron: Bool?
    let action: () -> Void
    @Environment(\.dsTheme) private var theme
    @Environment(\.dsTint) private var tint
    @State private var hover = false

    init(icon: String, title: String, selected: Bool = false, dim: Bool = false, chevron: Bool? = nil,
         action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.selected = selected
        self.dim = dim
        self.chevron = chevron
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5)).frame(width: 24)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
            if let chevron {
                Image(systemName: chevron ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(selected ? 1 : (dim ? 0.5 : 0.72)))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
            .fill(selected ? tint.opacity(0.26) : (hover ? .white.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

private struct HiddenRow: View {
    let module: Module
    let selected: Bool
    let action: () -> Void
    @Environment(\.dsTint) private var tint
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 18).opacity(0.6).frame(width: 24)
            Text(module.title).font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
            .fill(selected ? tint.opacity(0.26) : (hover ? .white.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .accessibilityAddTraits(.isButton)
    }
}
