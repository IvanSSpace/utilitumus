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

/// Экран модуля «Браузер».
struct BrowserView: View {
    @ObservedObject var catalog = BrowserCatalog.shared
    @State private var defaultID: String?
    @State private var busy = false
    @State private var errorText: String?
    @State private var addingRule = false
    @StateObject private var recorder = KeyRecorder()
    @AppStorage("Browser.introHidden") private var introHidden = false
    @Environment(\.dsTheme) private var theme

    private let probe = URL(string: "https://example.com")!
    private let rowHeight: CGFloat = 46

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
            if !introHidden { introSection }
            browsersSection
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    rulesColumn.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                    statusColumn.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: DS.blockSpacing) {
                    rulesColumn
                    statusColumn
                }
            }
        }
        .onAppear {
            catalog.refresh()
            refreshDefault()
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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

    private var introSection: some View {
        DSSection("Быстрый старт") {
            HStack(alignment: .top, spacing: 6) {
                introStep(icon: isDefault ? "checkmark.circle.fill" : "globe",
                          title: "Сделай браузером по умолчанию",
                          color: isDefault ? .green : tint) {
                    if !isDefault {
                        DSButton("Сделать", style: .primary, small: true) { setDefault(to: BrowserHelper.appURL) }
                            .disabled(busy)
                    }
                }
                introArrow
                introStep(icon: "link", title: "Кликни любую ссылку", color: .white.opacity(0.6)) {
                    DSButton("Попробовать", small: true) { openTest() }
                }
                introArrow
                introStep(icon: "cursorarrow.click.2", title: "Выбери браузер у курсора",
                          color: .white.opacity(0.6)) { EmptyView() }
                DSButton("", icon: "xmark", style: .plain, small: true) { introHidden = true }
                    .help("Скрыть быстрый старт")
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
        }
    }

    private var introArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.25))
            .frame(height: 24)
    }

    private func introStep<Extra: View>(icon: String, title: String, color: Color,
                                        @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(height: 24)
            Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    DSRow(icon: "checkmark.circle.fill", title: "Utilitumus — браузер по умолчанию",
                          subtitle: catalog.fallback == nil
                              ? "Отметь звёздочкой основной браузер: его можно вернуть системе."
                              : nil)
                    if let fallback = catalog.fallback {
                        DSRow(icon: "arrow.uturn.backward", title: "Вернуть системе",
                              subtitle: "Ссылки откроет \(fallback.name)") {
                            DSButton("Вернуть", small: true) { setDefault(to: fallback.url) }
                                .disabled(busy)
                        }
                    }
                } else {
                    DSRow(icon: "globe", title: "Пока не браузер по умолчанию",
                          subtitle: defaultName.map { "Сейчас ссылки открывает \($0)" })
                }
                if let errorText {
                    DSRow(icon: "exclamationmark.triangle", title: errorText)
                }
                DSRow(icon: "checkmark.seal", title: "Тестовая ссылка", subtitle: "Панель для example.com") {
                    DSButton("Проверить…", small: true) { openTest() }
                }
                if introHidden {
                    DSRow(icon: "lightbulb", title: "Быстрый старт") {
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
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Браузеры", trailing: "Порядок — перетаскиванием") {
                if catalog.browsers.isEmpty {
                    BRow(title: "Браузеры не найдены", dimmed: true, inset: 14) { EmptyView() } trailing: { EmptyView() }
                } else {
                    List {
                        ForEach(catalog.browsers) { browser in
                            browserRow(browser)
                                .frame(height: rowHeight)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { catalog.move(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(catalog.browsers.count) * rowHeight)
                }
            }
            caption("Своя клавиша — клик по значку с цифрой. Звёздочка — основной браузер.")
        }
    }

    private func browserRow(_ browser: InstalledBrowser) -> some View {
        let shown = !catalog.hidden.contains(browser.id)
        let isMain = catalog.fallbackID == browser.id
        let keyCode = catalog.effectiveKeys[browser.id]
        let recording = recorder.recordingID == browser.id
        return BRow(title: browser.name,
                    subtitle: recording ? "нажми клавишу · Delete — снять · Esc — отмена" : nil,
                    subtitleColor: recording ? tint : nil,
                    dimmed: !shown, minHeight: rowHeight) {
            Image(nsImage: browser.icon).resizable().frame(width: 28, height: 28)
                .opacity(shown ? 1 : 0.4)
        } trailing: {
            HStack(spacing: 10) {
                if !shown { DSChip("скрыт") }
                if shown {
                    keyBadge(browser, keyCode: keyCode, recording: recording)
                }
                Button {
                    catalog.setFallback(isMain ? nil : browser.id)
                } label: {
                    Image(systemName: isMain ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(isMain ? Color.yellow : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(isMain ? "Основной браузер" : "Сделать основным")
                DSToggle("Показывать в панели", isOn: Binding(
                    get: { shown },
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
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
            }
            caption("Подошло правило — ссылка открывается без панели. Работает первое подходящее сверху.")
        }
    }

    private func ruleRow(_ rule: BrowserRule) -> some View {
        let browser = catalog.browser(id: rule.browserID)
        let title: String
        switch rule.kind {
        case .domain: title = rule.value
        case .app: title = "из \(rule.title ?? rule.value)"
        }
        return BRow(title: title) {
            ruleIcon(rule)
        } trailing: {
            HStack(spacing: 8) {
                if rule.isPrivate { DSChip("приватно", icon: "eyeglasses") }
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                if let browser {
                    HStack(spacing: 5) {
                        Image(nsImage: browser.icon).resizable().frame(width: 16, height: 16)
                        Text(browser.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
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
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.value) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
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
            hotkeyRow("1–9", "открыть в браузере с этим номером")
            hotkeyRow("↑ ↓ ⏎", "выбрать и открыть")
            hotkeyRow("⌥", "зажми при выборе: приватное окно")
            hotkeyRow("⇧", "зажми: запомнить для сайта")
            hotkeyRow("⌘C", "скопировать ссылку")
            hotkeyRow("Esc", "отмена, клик мимо — тоже")
        }
    }

    private func hotkeyRow(_ keys: String, _ text: String) -> some View {
        BRow(title: text, inset: 14, minHeight: 40) { EmptyView() } trailing: { DSKeyCaps(keys) }
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
    @State private var browserID = ""
    @State private var isPrivate = false

    private var normalizedDomain: String? { BrowserRuleMatcher.normalizeDomain(domain) }
    private var browser: InstalledBrowser? { catalog.browser(id: browserID) }

    private var valid: Bool {
        guard browser != nil else { return false }
        return kind == .domain ? normalizedDomain != nil : app != nil
    }

    private var domainNote: String? {
        guard let normalizedDomain, normalizedDomain != domain.trimmingCharacters(in: .whitespaces) else { return nil }
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
                        TextField("", text: $domain, prompt: Text("google.com"))
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
                        ForEach(catalog.browsers) { browser in
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
            if browserID.isEmpty { browserID = catalog.fallbackID ?? catalog.pickerBrowsers.first?.id ?? "" }
        }
        .onChange(of: browserID) {
            if browser?.supportsPrivate != true { isPrivate = false }
        }
    }

    /// Запущенные обычные программы: именно из них чаще всего приходят ссылки.
    private var runningApps: [(id: String, name: String, icon: NSImage)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { running in
            guard running.activationPolicy == .regular, let id = running.bundleIdentifier, id != own,
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
