import SwiftUI
import AppKit

/// Строка карточки с произвольным значком слева: та же геометрия, что у `DSRow`
/// (значки браузеров и приложений — картинки, а не SF Symbols).
private struct BRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var dimmed = false
    var inset: CGFloat = 56
    var minHeight: CGFloat = 50
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.rowTitle).lineLimit(1)
                    .foregroundStyle(.white.opacity(dimmed ? 0.5 : 0.95))
                if let subtitle {
                    Text(subtitle).font(DS.rowSubtitle).lineLimit(1)
                        .foregroundStyle(subtitleColor ?? .white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(minHeight: minHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, inset)
        }
    }
}

/// Чипы в несколько строк с переносом.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal.width ?? 360, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(bounds.width, subviews)
        for (subview, point) in zip(subviews, result.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

/// Экран модуля «Браузер».
struct BrowserView: View {
    @Environment(\.pageActive) private var pageActive
    @ObservedObject var catalog = BrowserCatalog.shared
    @State private var defaultID: String?
    @State private var busy = false
    @State private var errorText: String?
    @State private var addingRule = false
    @StateObject private var recorder = KeyRecorder()
    @AppStorage("Browser.introHidden") private var introHidden = false
    @Environment(\.dsTheme) private var theme

    private let probe = URL(string: "https://example.com")!
    private let rowHeight: CGFloat = 44

    private var isDefault: Bool { defaultID == BrowserHelper.bundleID }
    /// Акцент модуля: `DSPage` кладёт его в окружение только для содержимого, а здесь он нужен в самом экране.
    private var tint: Color { theme.accent(.browser) }

    private var primary: DSAction {
        isDefault
            ? DSAction("Проверить", icon: "checkmark.seal") { openTest() }
            : DSAction("Сделать основным", icon: "checkmark.seal.fill") { if !busy { setDefault(to: BrowserHelper.appURL) } }
    }

    var body: some View {
        DSPage(module: .browser, primary: primary) {
            if !introHidden && !isDefault { introStrip }
            // Две колонки: слева браузеры и правила, справа статус и клавиши. Узкое окно — одна колонка.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) { browsersSection; rulesColumn }
                        .frame(minWidth: 350, idealWidth: 350, maxWidth: .infinity)
                    statusColumn.frame(width: 300)
                }
                VStack(alignment: .leading, spacing: DS.blockSpacing) {
                    browsersSection
                    rulesColumn
                    statusColumn
                }
            }
        }
        .onPageActive { active in
            if active {
                catalog.refresh()
                refreshDefault()
            } else {
                recorder.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard pageActive else { return }
            catalog.refresh()
            refreshDefault()
        }
        .sheet(isPresented: $addingRule) { AddRuleSheet(catalog: catalog).dsThemed() }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    // MARK: - Быстрый старт

    /// Одна строка вместо карточки: показывается, пока Utilitumus не стал браузером по умолчанию.
    private var introStrip: some View {
        HStack(spacing: 8) {
            introStep("globe", "Сделай браузером по умолчанию")
            introArrow
            introStep("link", "Кликни любую ссылку")
            introArrow
            introStep("cursorarrow.click.2", "Выбери браузер у курсора")
            Spacer(minLength: 0)
            DSButton("", icon: "xmark", style: .plain, small: true) { introHidden = true }
                .help("Скрыть быстрый старт")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
    }

    private var introArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.25))
    }

    private func introStep(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
        }
    }

    // MARK: - Статус

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            statusSection
            hotkeysSection
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Статус") {
                if isDefault {
                    BRow(title: "Браузер по умолчанию", subtitle: "Utilitumus", minHeight: 44) {
                        symbolTile("checkmark.circle.fill")
                    } trailing: { EmptyView() }
                    if let fallback = catalog.fallback {
                        BRow(title: "Вернуть системе", subtitle: fallback.name, minHeight: 44) {
                            symbolTile("arrow.uturn.backward")
                        } trailing: {
                            DSButton("Вернуть", small: true) { setDefault(to: fallback.url) }.disabled(busy)
                        }
                    } else {
                        BRow(title: "Нет основного браузера", subtitle: "Отметь звёздочкой, чтобы вернуть", minHeight: 44) {
                            symbolTile("arrow.uturn.backward")
                        } trailing: { EmptyView() }
                    }
                } else {
                    BRow(title: "Не по умолчанию", subtitle: defaultName.map { "Сейчас: \($0)" }, minHeight: 44) {
                        symbolTile("globe")
                    } trailing: { EmptyView() }
                }
                if let errorText {
                    BRow(title: errorText, minHeight: 44) { symbolTile("exclamationmark.triangle") } trailing: { EmptyView() }
                }
                BRow(title: "Тест-ссылка", subtitle: "example.com", minHeight: 44) {
                    symbolTile("checkmark.seal")
                } trailing: {
                    DSButton("Проверить", small: true) { openTest() }
                }
                if introHidden && !isDefault {
                    BRow(title: "Быстрый старт", minHeight: 44) { symbolTile("lightbulb") } trailing: {
                        DSButton("Показать", small: true) { introHidden = false }
                    }
                }
            }
            caption("macOS спросит подтверждение. Выключишь модуль — ссылки пойдут в основной браузер.")
        }
    }

    private var defaultName: String? {
        guard let defaultID, defaultID != BrowserHelper.bundleID else { return nil }
        if let known = catalog.browser(id: defaultID) { return known.name }
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func refreshDefault() {
        defaultID = NSWorkspace.shared.urlForApplication(toOpen: probe).flatMap { Bundle(url: $0)?.bundleIdentifier }
        BrowserLinkHandler.live.noteDefault()
    }

    /// Тестовая ссылка идёт тем же путём, что и настоящая: через помощника.
    private func openTest() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([BrowserHelper.testURL], withApplicationAt: BrowserHelper.appURL,
                                configuration: configuration) { _, error in
            if let error { NSLog("Utilitumus: помощник ссылок не запустился: %@", error.localizedDescription) }
        }
    }

    /// Системный обработчик для обеих схем; macOS покажет своё подтверждение.
    private func setDefault(to appURL: URL) {
        LSRegisterURL(appURL as CFURL, true)
        busy = true
        errorText = nil
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
                }
            } catch {
                errorText = "Не получилось: \(error.localizedDescription)"
            }
            busy = false
            refreshDefault()
        }
    }

    // MARK: - Браузеры

    private var browsersSection: some View {
        let shown = catalog.pickerBrowsers
        let hiddenList = catalog.browsers.filter { catalog.hidden.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            DSSection("Браузеры", trailing: "Порядок — перетаскиванием") {
                if catalog.browsers.isEmpty {
                    BRow(title: "Браузеры не найдены", dimmed: true, inset: 14) { EmptyView() } trailing: { EmptyView() }
                } else {
                    if shown.isEmpty {
                        BRow(title: "Все браузеры скрыты", dimmed: true, inset: 14, minHeight: rowHeight) { EmptyView() } trailing: { EmptyView() }
                    } else {
                        List {
                            ForEach(shown) { browser in
                                browserRow(browser)
                                    .frame(height: rowHeight)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            .onMove { moveShown(shown, from: $0, to: $1) }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: CGFloat(shown.count) * rowHeight)
                    }
                    if !hiddenList.isEmpty { hiddenStrip(hiddenList) }
                }
            }
            caption("Клик по цифре — своя клавиша. Звёздочка — основной.")
        }
    }

    /// Порядок перетаскивают среди показанных; в полном списке сдвигаем на места этих же браузеров.
    private func moveShown(_ shown: [InstalledBrowser], from source: IndexSet, to destination: Int) {
        let all = catalog.browsers
        guard let from = source.first, let src = all.firstIndex(of: shown[from]) else { return }
        let dst = destination < shown.count
            ? all.firstIndex(of: shown[destination]) ?? all.count
            : (all.firstIndex(of: shown[shown.count - 1]).map { $0 + 1 } ?? all.count)
        catalog.move(from: IndexSet(integer: src), to: dst)
    }

    /// Скрытые браузеры: компактные чипы, клик возвращает в панель.
    private func hiddenStrip(_ list: [InstalledBrowser]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ещё \(list.count) — клик вернёт в панель")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            FlowLayout(spacing: 6) {
                ForEach(list) { browser in
                    Button {
                        catalog.setHidden(browser.id, false)
                    } label: {
                        HStack(spacing: 5) {
                            Image(nsImage: browser.icon).resizable().frame(width: 16, height: 16)
                            Text(browser.name).font(.system(size: 12)).lineLimit(1)
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Показывать \(browser.name) в панели")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
    }

    private func browserRow(_ browser: InstalledBrowser) -> some View {
        let isMain = catalog.fallback?.id == browser.id
        let keyCode = catalog.effectiveKeys[browser.id]
        let recording = recorder.recordingID == browser.id
        return BRow(title: browser.name,
                    subtitle: recording ? "нажми клавишу · ⌫ снять · Esc" : nil,
                    subtitleColor: recording ? tint : nil,
                    minHeight: rowHeight) {
            Image(nsImage: browser.icon).resizable().frame(width: 28, height: 28)
        } trailing: {
            HStack(spacing: 10) {
                keyBadge(browser, keyCode: keyCode, recording: recording)
                // Основным может быть только то, чему можно верить (см. `BrowserRouting`).
                if catalog.canTarget(browser.id) {
                    Button {
                        catalog.setFallback(isMain ? nil : browser.id)
                    } label: {
                        Image(systemName: isMain ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(isMain ? Color.yellow : .white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help(isMain ? "Основной браузер" : "Сделать основным")
                }
                DSToggle("Показывать в панели", isOn: Binding(
                    get: { true },
                    set: { catalog.setHidden(browser.id, !$0) }
                ))
            }
        }
    }

    /// Бейдж клавиши, как на панели. Клик — запись новой клавиши.
    private func keyBadge(_ browser: InstalledBrowser, keyCode: UInt16?, recording: Bool) -> some View {
        let own = catalog.keys[browser.id] != nil
        return Button {
            recorder.start(for: browser.id, catalog: catalog)
        } label: {
            Text(recording ? "…" : keyCode.flatMap(BrowserKeys.label(for:)) ?? "–")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.black.opacity(0.8) : .white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? tint : .white.opacity(own ? 0.16 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(own ? 0.3 : 0.14), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .help(own ? "Своя клавиша: клик — сменить" : "Клавиша по порядку: клик — назначить свою")
    }

    // MARK: - Правила

    private var rulesColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Правила", trailing: catalog.rules.isEmpty ? nil : "\(catalog.rules.count)") {
                if catalog.rules.isEmpty {
                    BRow(title: "Правил нет", dimmed: true, inset: 14) { EmptyView() } trailing: { EmptyView() }
                }
                ForEach(catalog.rules) { rule in
                    ruleRow(rule)
                }
                HStack {
                    DSButton("Добавить правило", icon: "plus", small: true) { addingRule = true }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
            }
            caption("Подошло правило — ссылка открывается без панели. Первое сверху главнее.")
        }
    }

    private func ruleRow(_ rule: BrowserRule) -> some View {
        let browser = catalog.browser(id: rule.browserID)
        let title: String
        switch rule.kind {
        case .domain: title = rule.value
        case .app: title = "из \(rule.title ?? rule.value)"
        }
        return BRow(title: title, minHeight: 44) {
            ruleIcon(rule)
        } trailing: {
            HStack(spacing: 8) {
                if rule.isPrivate { Image(systemName: "eyeglasses").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).help("Приватное окно") }
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                if let browser {
                    HStack(spacing: 5) {
                        Image(nsImage: browser.icon).resizable().frame(width: 16, height: 16)
                        Text(browser.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.1)))
                } else {
                    DSChip("браузер не найден", color: .orange)
                }
                Button {
                    catalog.removeRule(rule.id)
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Удалить правило")
            }
        }
    }

    @ViewBuilder
    private func ruleIcon(_ rule: BrowserRule) -> some View {
        switch rule.kind {
        case .domain:
            symbolTile("globe")
        case .app:
            if let icon = catalog.appIcon(bundleID: rule.value) {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            } else {
                symbolTile("app")
            }
        }
    }

    private func symbolTile(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint))
    }

    // MARK: - Подсказка

    private var hotkeysSection: some View {
        DSSection("Клавиши на панели") {
            hotkeyRow("1–9", "браузер по номеру")
            hotkeyRow("↑ ↓ ⏎", "выбрать и открыть")
            hotkeyRow("⌥", "приватное окно")
            hotkeyRow("⇧", "запомнить для сайта")
            hotkeyRow("⌘C", "скопировать ссылку")
            hotkeyRow("Esc", "отмена")
        }
    }

    private func hotkeyRow(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            DSKeyCaps(keys).frame(width: 74, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .frame(minHeight: 30)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
    }
}

/// Запись клавиши для браузера: пока идёт, следующая нажатая клавиша назначается, остальное глотается.
/// Клик мимо и Esc отменяют, Delete снимает свою клавишу.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var recordingID: String?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func start(for id: String, catalog: BrowserCatalog) {
        stop()
        recordingID = id
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak catalog] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard let self, let catalog else { return false }
                return self.handleKey(keyCode, flags: flags, id: id, catalog: catalog)
            }
            return handled ? nil : event
        }
        // Клик мимо отменяет; клик по самому бейджу тут же запустит запись заново.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.stop() }
            return event
        }
    }

    /// true — клавишу съели (назначили, сняли или отменили); false — пропускаем дальше.
    private func handleKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, id: String, catalog: BrowserCatalog) -> Bool {
        // ⌘ и Ctrl — это команды приложения (⌘Q, ⌘W), их не трогаем.
        if !flags.intersection([.command, .control]).isEmpty { return false }
        switch keyCode {
        case 53:
            stop()
        case 51, 117:
            catalog.setKey(nil, for: id)
            stop()
        default:
            if BrowserKeys.isAssignable(keyCode) {
                catalog.setKey(keyCode, for: id)
                stop()
            }
        }
        return true
    }

    func stop() {
        recordingID = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }
}


/// Лист «Добавить правило»: сайт или приложение → браузер.
private struct AddRuleSheet: View {
    @ObservedObject var catalog: BrowserCatalog
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dsTheme) private var theme

    @State private var kind: BrowserRule.Kind = .domain
    @State private var domain = ""
    @State private var app: (id: String, name: String, icon: NSImage)?
    @State private var runningApps: [(id: String, name: String, icon: NSImage)] = []
    @State private var browserID = ""
    @State private var isPrivate = false

    private var normalizedDomain: String? { BrowserRuleMatcher.normalizePattern(domain) }
    private var browser: InstalledBrowser? { catalog.browser(id: browserID) }

    private var valid: Bool {
        guard browser != nil else { return false }
        return kind == .domain ? normalizedDomain != nil : app != nil
    }

    private var domainNote: String? {
        guard let normalizedDomain else { return nil }
        if normalizedDomain.contains("/") {
            return "Только ссылки на \(normalizedDomain)/…: правило с путём важнее правила на весь сайт."
        }
        guard normalizedDomain != domain.trimmingCharacters(in: .whitespaces) else { return nil }
        return "Сохранится как \(normalizedDomain). Поддомены тоже подойдут."
    }

    private var privateNote: String? {
        guard let browser, !browser.supportsPrivate else { return nil }
        return "\(browser.name) не умеет открывать приватное окно из командной строки."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новое правило").font(.system(size: 20, weight: .bold, design: .rounded))

            DSSection("Условие") {
                DSRow(icon: "line.3.horizontal.decrease", title: "Когда") {
                    DSSegmented([BrowserRule.Kind.domain, .app], selection: $kind) {
                        $0 == .domain ? "Сайт" : "Приложение"
                    }
                }
                if kind == .domain {
                    DSRow(icon: "globe", title: "Домен", subtitle: domainNote) {
                        TextField("", text: $domain, prompt: Text("google.com или github.com/apple"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 170)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
                    }
                } else {
                    DSRow(icon: "app", title: "Ссылка из") {
                        Menu {
                            ForEach(runningApps, id: \.id) { candidate in
                                Button {
                                    app = candidate
                                } label: {
                                    Text(candidate.name)
                                }
                            }
                            Divider()
                            Button("Другое приложение…") { chooseFromDisk() }
                        } label: {
                            if let app {
                                HStack(spacing: 6) {
                                    Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                                    Text(app.name)
                                }
                            } else {
                                Text("Выбрать приложение")
                            }
                        }
                        .fixedSize()
                    }
                }
            }

            DSSection("Куда открывать") {
                DSRow(icon: "safari", title: "Открывать в") {
                    Picker("Открывать в", selection: $browserID) {
                        // Правило на приложение, которому нельзя верить, открывает панель. Новое такое завести нельзя, старое видно.
                        ForEach(catalog.browsers.filter { catalog.canTarget($0.id) || $0.id == browserID }) { browser in
                            Text(browser.name).tag(browser.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DSRow(icon: "eyeglasses", title: "Приватное окно", subtitle: privateNote) {
                    DSToggle("Приватное окно", isOn: $isPrivate)
                        .disabled(browser?.supportsPrivate != true)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                DSButton("Отмена", style: .plain) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                DSButton("Добавить", style: .primary) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(LinearGradient(colors: theme.background(.browser), startPoint: .top, endPoint: .bottom))
        .environment(\.dsTint, theme.accent(.browser))
        .onAppear {
            if runningApps.isEmpty { runningApps = Self.loadRunningApps() }
            if browserID.isEmpty {
                browserID = catalog.fallback?.id ?? catalog.pickerBrowsers.first { catalog.canTarget($0.id) }?.id ?? ""
            }
        }
        .onChange(of: browserID) {
            if browser?.supportsPrivate != true { isPrivate = false }
        }
    }

    /// Запущенные обычные программы: именно из них чаще всего приходят ссылки.
    private static func loadRunningApps() -> [(id: String, name: String, icon: NSImage)] {
        return NSWorkspace.shared.runningApplications.compactMap { running in
            guard running.activationPolicy == .regular, let id = running.bundleIdentifier, !Kit.isOurs(id),
                  let name = running.localizedName else { return nil }
            return (id, name, running.icon ?? NSImage())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        app = (id, name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
    }

    private func add() {
        guard let browser else { return }
        let rule: BrowserRule?
        switch kind {
        case .domain:
            rule = normalizedDomain.map {
                BrowserRule(kind: .domain, value: $0, browserID: browser.id, isPrivate: isPrivate)
            }
        case .app:
            rule = app.map {
                BrowserRule(kind: .app, value: $0.id, browserID: browser.id, isPrivate: isPrivate, title: $0.name)
            }
        }
        if let rule { catalog.addRule(rule) }
        dismiss()
    }
}
