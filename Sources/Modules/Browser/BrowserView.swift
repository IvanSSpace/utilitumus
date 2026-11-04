import SwiftUI
import AppKit

/// Экран модуля «Браузер».
struct BrowserView: View {
    @ObservedObject var catalog = BrowserCatalog.shared
    @State private var defaultID: String?
    @State private var busy = false
    @State private var errorText: String?
    @State private var addingRule = false
    @StateObject private var recorder = KeyRecorder()

    private let probe = URL(string: "https://example.com")!
    private let rowHeight: CGFloat = 46

    private var isDefault: Bool { defaultID == BrowserHelper.bundleID }

    var body: some View {
        Form {
            statusSection
            browsersSection
            rulesSection
            hotkeysSection
            Section {
                Button("Проверить…") { openTest() }
            } footer: {
                Text("Показывает панель выбора с https://example.com — можно попробовать, не делая Utilitumus браузером по умолчанию.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Браузер")
        .navigationSubtitle("Выбор браузера для каждой ссылки")
        .onAppear {
            catalog.refresh()
            refreshDefault()
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            catalog.refresh()
            refreshDefault()
        }
        .sheet(isPresented: $addingRule) { AddRuleSheet(catalog: catalog) }
    }

    // MARK: - Статус

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if isDefault {
                Label("Utilitumus — браузер по умолчанию", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let fallback = catalog.fallback {
                    LabeledContent("Вернуть системе") {
                        Button("Вернуть \(fallback.name)") { setDefault(to: fallback.url) }
                            .disabled(busy)
                    }
                } else {
                    Text("Отметь звёздочкой основной браузер ниже: его можно будет вернуть системе одной кнопкой.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Utilitumus пока не браузер по умолчанию", systemImage: "globe")
                        .font(.callout)
                    if let name = defaultName {
                        Text("Сейчас ссылки открывает \(name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Сделать браузером по умолчанию") { setDefault(to: BrowserHelper.appURL) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                .padding(.vertical, 4)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Статус")
        } footer: {
            Text("macOS сама спросит подтверждение. Если выключить модуль, ссылки откроются в основном браузере.")
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

    @ViewBuilder
    private var browsersSection: some View {
        Section {
            if catalog.browsers.isEmpty {
                Text("Браузеры не найдены").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(catalog.browsers) { browser in
                        browserRow(browser)
                            .frame(height: rowHeight)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    }
                    .onMove { catalog.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: CGFloat(catalog.browsers.count) * rowHeight + 8)
            }
        } header: {
            Text("Браузеры в панели выбора")
        } footer: {
            Text("Порядок меняется перетаскиванием, клавиша выбора — кликом по значку с цифрой: нажми нужную клавишу (0–9 или A–Z, на любой раскладке), Delete вернёт автоматическую, Esc отменит. Автоматические клавиши — цифры 1–9 по порядку, мимо занятых. Звёздочка — основной браузер: в него уходят ссылки, когда модуль выключен, и он выделен в панели заранее. Незнакомые приложения, которые умеют открывать ссылки, по умолчанию скрыты.")
        }
    }

    private func browserRow(_ browser: InstalledBrowser) -> some View {
        let shown = !catalog.hidden.contains(browser.id)
        let isMain = catalog.fallbackID == browser.id
        let keyCode = catalog.effectiveKeys[browser.id]
        let recording = recorder.recordingID == browser.id
        return HStack(spacing: 10) {
            Image(nsImage: browser.icon).resizable().frame(width: 30, height: 30)
                .opacity(shown ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.name)
                    .foregroundStyle(shown ? .primary : .secondary)
                if recording {
                    Text("нажми клавишу · Delete — снять · Esc — отмена")
                        .font(.caption).foregroundStyle(Color.accentColor)
                } else if !shown {
                    Text("скрыт").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if shown {
                keyBadge(browser, keyCode: keyCode, recording: recording)
            }
            Button {
                catalog.setFallback(isMain ? nil : browser.id)
            } label: {
                Image(systemName: isMain ? "star.fill" : "star")
                    .foregroundStyle(isMain ? Color.yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isMain ? "Основной браузер" : "Сделать основным")
            Toggle("Показывать в панели", isOn: Binding(
                get: { shown },
                set: { catalog.setHidden(browser.id, !$0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    /// Бейдж клавиши, как на панели: скруглённый квадрат с обводкой. Клик — запись новой клавиши.
    private func keyBadge(_ browser: InstalledBrowser, keyCode: UInt16?, recording: Bool) -> some View {
        let own = catalog.keys[browser.id] != nil
        return Button {
            recorder.start(for: browser.id, catalog: catalog)
        } label: {
            Text(recording ? "…" : keyCode.flatMap(BrowserKeys.label(for:)) ?? "–")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.white : .primary)
                .frame(width: 24, height: 24)
                .background(recording ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(recording ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help(own ? "Своя клавиша: клик — сменить" : "Клавиша по порядку: клик — назначить свою")
    }

    // MARK: - Правила

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if catalog.rules.isEmpty {
                Text("Правил нет").foregroundStyle(.secondary)
            }
            ForEach(catalog.rules) { rule in
                ruleRow(rule)
            }
            Button("Добавить правило…") { addingRule = true }
        } header: {
            Text("Правила")
        } footer: {
            Text("Подошло правило — ссылка открывается сразу, без панели. Домен ловит и поддомены: google.com откроет и meet.google.com. Работает первое подошедшее правило сверху. Правило для сайта можно создать прямо из панели.")
        }
    }

    private func ruleRow(_ rule: BrowserRule) -> some View {
        let browser = catalog.browser(id: rule.browserID)
        return HStack(spacing: 10) {
            ruleCondition(rule)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            if let browser {
                Image(nsImage: browser.icon).resizable().frame(width: 22, height: 22)
                Text(browser.name)
            } else {
                Text("браузер не найден").foregroundStyle(.orange)
            }
            if rule.isPrivate {
                Label("приватно", systemImage: "eyeglasses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                catalog.removeRule(rule.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Удалить правило")
        }
    }

    @ViewBuilder
    private func ruleCondition(_ rule: BrowserRule) -> some View {
        switch rule.kind {
        case .domain:
            Label(rule.value, systemImage: "globe")
        case .app:
            HStack(spacing: 6) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.value) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app").frame(width: 20, height: 20)
                }
                Text("из \(rule.title ?? rule.value)")
            }
        }
    }

    // MARK: - Подсказка

    private var hotkeysSection: some View {
        Section("Клавиши на панели") {
            LabeledContent("1–9", value: "открыть в браузере с этим номером")
            LabeledContent("↑ ↓, Enter", value: "выбрать и открыть")
            LabeledContent("⌥", value: "зажать при выборе: приватное окно")
            LabeledContent("⇧", value: "зажать при выборе: запомнить для сайта")
            LabeledContent("⌘C", value: "скопировать ссылку")
            LabeledContent("Esc", value: "отмена, клик мимо — тоже")
        }
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Условие") {
                    SegmentedControl([BrowserRule.Kind.domain, .app], selection: $kind) {
                        $0 == .domain ? "Сайт" : "Приложение"
                    }
                }

                if kind == .domain {
                    TextField("Домен", text: $domain, prompt: Text("google.com"))
                    if let normalizedDomain, normalizedDomain != domain.trimmingCharacters(in: .whitespaces) {
                        Text("Будет сохранён как \(normalizedDomain). Поддомены тоже подойдут.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Ссылка из") {
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

                Picker("Открывать в", selection: $browserID) {
                    ForEach(catalog.browsers) { browser in
                        Text(browser.name).tag(browser.id)
                    }
                }
                Toggle("Приватное окно", isOn: $isPrivate)
                    .disabled(browser?.supportsPrivate != true)
                if let browser, !browser.supportsPrivate {
                    Text("\(browser.name) не умеет открывать приватное окно из командной строки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Добавить") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 440)
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
