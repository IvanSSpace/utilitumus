import SwiftUI
import AppKit
import Combine

// Дашборд: страница по умолчанию. Три секции по категориям, у каждого модуля — живой статус
// и одно быстрое действие. Статусы читаются из настоящих контроллеров только у включённых модулей
// и ничего не запускают: ни таймеров, ни подписок на систему.
//
// Статус модуля — отдельный `DashSlot`: он подписывается на контроллер, пока статус на экране (карточка
// дашборда, строка с подписью в боковой панели), считает текст при событии и публикует его, только если
// он реально изменился. Разбудить перерисовкой можно лишь ту карточку или строку, чей статус поменялся.

// MARK: - Живые статусы

/// Видно ли окно приложения: скрытое или свёрнутое окно ничего не рисует, статусы считать незачем.
@MainActor
final class WindowVisibility: ObservableObject {
    static let shared = WindowVisibility()
    @Published private(set) var isVisible = true

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
        }
        recompute()
    }

    private func recompute() {
        #if KIT_TEST_DEFAULTS
        // Окно стенда за экраном и всегда перекрыто, а картинку снимает cacheDisplay.
        let visible = true
        #else
        let visible = NSApp.map { app in
            !app.isHidden && app.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        } ?? true
        #endif
        if visible != isVisible { isVisible = visible }
    }
}

/// Статус одного модуля. Подписки живут, пока есть хоть один показывающий его экран (`attach`/`detach`)
/// и окно видно; при показе окна статус обновляется один раз.
@MainActor
final class DashSlot: ObservableObject {
    let module: Module
    @Published private(set) var state: DashState
    private var attached = 0
    private var subs: [AnyCancellable] = []
    private var sourceSub: AnyCancellable?
    /// На что подписан `sourceSub`: при передаче утилите или возврате подписку надо сменить.
    private enum SourceKind { case none, model }
    private var sourceKind = SourceKind.none
    private var visibilitySub: AnyCancellable?

    fileprivate init(_ module: Module) {
        self.module = module
        state = DashboardLive.compute(module)
    }

    func attach() {
        attached += 1
        guard attached == 1 else { return }
        visibilitySub = WindowVisibility.shared.$isVisible.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    func detach() {
        attached = max(0, attached - 1)
        guard attached == 0 else { return }
        visibilitySub = nil
        stop()
    }

    /// Модель, у которой включено слежение за дашбордом: снять его надо у неё же, даже если модуль уже вернулся.
    private var watched: (any RemoteModuleSurface)?

    private func stop() {
        subs = []
        sourceSub = nil
        watched?.setDashboardVisible(false)
        watched = nil
    }

    private func reconcile() {
        guard attached > 0, WindowVisibility.shared.isVisible else { stop(); return }
        if subs.isEmpty {
            // willChange приходит до смены значения: читаем контроллер со следующего витка.
            subs = [
                ModuleManager.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() },
                AccessState.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() },
                SatelliteRegistry.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() },
            ]
        }
        // Как при открытии вкладки: один раз, пока статус не был на экране, утилита могла зависнуть.
        // Живые данные карточки утилита шлёт, только пока дашборд виден.
        let model = ModuleManager.shared.isExternal(module) ? RemoteModules.model(module) : nil
        if watched !== model {
            watched?.setDashboardVisible(false)
            watched = model
            model?.setDashboardVisible(true)
        }
        DashboardLive.refreshExternal(module)
        update()
    }

    private func syncSource() {
        let kind: SourceKind = DashboardLive.hasRemoteModel(module) ? .model : .none
        guard kind != sourceKind || (kind != .none && sourceSub == nil) else { return }
        sourceKind = kind
        guard kind != .none, let source = DashboardLive.source(module) else {
            sourceSub = nil
            return
        }
        // Не чаще раза в секунду: вентиляторы публикуют каждые 2 с.
        sourceSub = source
            .receive(on: DispatchQueue.main)
            .throttle(for: 1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.update() }
    }

    private func update() {
        syncSource()
        let new = DashboardLive.compute(module)
        if new != state { state = new }
    }
}

/// Реестр статусов модулей. Контроллер выключенного модуля не читается и не трогается.
@MainActor
enum DashboardLive {
    private static let slots: [Module: DashSlot] = Dictionary(
        uniqueKeysWithValues: Module.allCases.map { ($0, DashSlot($0)) })

    static func slot(_ module: Module) -> DashSlot { slots[module]! }

    /// Модуль ведёт утилита, а экран у него свой, с моделью в центре (`RemoteModules`). Остальным хватает строки статуса.
    fileprivate static func hasRemoteModel(_ module: Module) -> Bool {
        ModuleManager.shared.isExternal(module) && RemoteModules.model(module) != nil
    }

    /// Как при открытии вкладки: пока статус не был на экране, утилита могла зависнуть.
    fileprivate static func refreshExternal(_ module: Module) {
        guard ModuleManager.shared.isExternal(module) else { return }
        if let model = RemoteModules.model(module) { model.refresh() } else { SatelliteRegistry.shared.refresh(module) }
    }

    /// Что слушать, пока модуль на экране: его модель (статус слушает реестр).
    fileprivate static func source(_ module: Module) -> AnyPublisher<Void, Never>? {
        ModuleManager.shared.isExternal(module) ? RemoteModules.model(module)?.changes : nil
    }

    /// Быстрое действие карточки. `ask` — показать подтверждение, если оно нужно.
    static func perform(_ module: Module, ask: (DashConfirmation) -> Void) {
        if ModuleManager.shared.isExternal(module) { performExternal(module, ask: ask) }
    }

    /// Переключатель модуля на карточке: утилита выключается у себя, `ModuleOn` — настройка встроенного.
    static func setOn(_ module: Module, _ on: Bool) {
        if ModuleManager.shared.isExternal(module) {
            SatelliteRegistry.shared.setEnabled(module, on)
        } else {
            ModuleManager.shared.setOn(module, on)
        }
    }

    #if KIT_TEST_DEFAULTS
    /// Карточка встроенного модуля, которую проверка задаёт сама: настоящим контроллерам нужны железо и данные человека.
    static var testBuiltIn: [Module: DashState] = [:]
    #endif

    /// Состояние карточки сейчас, без подписки: значок в строке меню читает его при открытии меню.
    static func snapshot(_ module: Module) -> DashState { compute(module) }

    fileprivate static func compute(_ module: Module) -> DashState {
        #if KIT_TEST_DEFAULTS
        if !ModuleManager.shared.isExternal(module), let fixture = testBuiltIn[module] { return fixture }
        #endif
        if ModuleManager.shared.isExternal(module) {
            return externalState(status: SatelliteRegistry.shared.entries[module]?.status,
                                 model: RemoteModules.model(module))
        }
        guard ModuleManager.shared.isOn(module) else { return DashState(on: false, text: "выключен") }
        return DashState(text: "утилита не установлена", attention: true)
    }

    /// Карточка ведомого модуля из статуса утилиты: те же состояния, что у встроенного (выключен, нужен доступ,
    /// оранжевое, действие). Чистая функция: проверка не нуждается ни в утилите, ни в центре.
    /// `model` — тот, чья карточка показывает больше, чем строка статуса.
    static func externalState(status: LinkStatus?, model: (any RemoteModuleSurface)?) -> DashState {
        if let model {
            if !model.responding { return DashState(text: "не отвечает", attention: true) }
        } else if status == nil {
            return DashState(text: "не отвечает", attention: true)
        }
        if status?.enabled == false { return DashState(on: false, text: "выключен") }
        if let status, status.needsSetup > 0 { return DashState(text: "нужен доступ", attention: true) }
        var base = DashState(text: status?.line ?? "", attention: status?.attention ?? false)
        if let quick = status?.quickActions.first {
            base.actionTitle = quick.title
            base.actionIcon = quick.icon
            base.quick = quick
        }
        return model?.dashboardState(base: base, status: status) ?? base
    }

    private static func performExternal(_ module: Module, ask: (DashConfirmation) -> Void) {
        if RemoteModules.model(module)?.performDashboardAction(ask: ask) == true { return }
        guard let quick = slot(module).state.quick else { return }
        SatelliteRegistry.shared.confirmAndPerform(quick, module: module, ask: ask)
    }

    private static func sound() -> DashState {
        let name = MonitorState.shared.currentInputName
        return DashState(text: name == "—" ? "слежу за микрофоном" : name)
    }

    private static func mouse() -> DashState {
        let s = MouseController.shared.settings
        guard s.needsTap else { return DashState(text: "всё как в системе") }
        var parts: [String] = []
        if s.mouseDirection == .reversed || s.magicMouseDirection == .reversed { parts.append("прокрутка обратная") }
        if s.smoothEnabled { parts.append("плавность \(Int((s.smoothness * 100).rounded())) %") }
        return DashState(text: parts.joined(separator: " · "))
    }

    private static func fans() -> DashState {
        let c = FanController.shared
        if c.safetyTripped { return DashState(text: "перегрев · вентиляторами управляет система", attention: true) }
        var parts: [String] = []
        if let t = c.cpuMax { parts.append("\(Int(t.rounded()))°") }
        if c.fullPower {
            parts.append("Макс")
        } else {
            let modes = Set(c.configs.map(\.mode))
            parts.append(modes.count > 1 ? "Разные режимы" : (modes.first ?? .auto).title)
        }
        if let rpm = c.fans.map(\.actual).max() { parts.append("\(Int(rpm.rounded())) об/мин") }
        var state = DashState(text: parts.joined(separator: " · "))
        // Без доступа помощника кнопка ничего бы не сделала.
        if FanHelperInstaller.shared.status == .ready && c.conflictingApp == nil {
            state.actionTitle = c.fullPower ? "Авто" : "Максимум"
            state.actionIcon = c.fullPower ? "arrow.uturn.backward" : "wind"
        }
        return state
    }

    private static func browser() -> DashState {
        let catalog = BrowserCatalog.shared
        let text: String
        if let main = catalog.fallback {
            text = "основной: \(main.name)"
        } else {
            text = catalog.browsers.isEmpty ? "ищу браузеры…" : "основной не выбран"
        }
        return DashState(text: text, actionTitle: "Проверить")
    }

    private static func stash() -> DashState {
        let store = StashStore.shared
        if !store.stashed.isEmpty {
            return DashState(text: "спрятано \(store.stashed.count) · можно вернуть",
                             actionTitle: "Вернуть", actionIcon: "arrow.uturn.backward")
        }
        if let busy = store.busy { return DashState(text: busy) }
        let selected = store.selected
        guard !selected.isEmpty else { return DashState(text: "нет программ для закрытия") }
        let freed = selected.reduce(0.0) { $0 + (store.usage[$1.bundleIdentifier ?? ""]?.memoryMB ?? 0) }
        let tail = freed > 0 ? " · ≈ \(memoryText(freed))" : ""
        return DashState(text: "выбрано \(selected.count)\(tail)", actionTitle: "Спрятать", actionIcon: "archivebox")
    }

    private static func clipboard() -> DashState {
        let controller = ClipboardController.shared
        if controller.storeError != nil { return DashState(text: "нет ключа шифрования", attention: true) }
        return DashState(text: "\(controller.hotKeyLabel) · \(controller.items.count) записей")
    }

    private static func voice() -> DashState {
        let controller = VoiceController.shared
        let models = VoiceModelStore.shared
        if controller.phase == .recording { return DashState(text: "идёт запись…") }
        let model = models.selected.title.components(separatedBy: " — ")[0]
        if models.status(models.selected) != .installed {
            return DashState(text: "\(controller.hotKeyLabel) · модель не скачана", attention: true)
        }
        return DashState(text: "\(controller.hotKeyLabel) · \(model)")
    }

    private static func keyboard() -> DashState {
        let c = KeyboardController.shared
        let fn = c.isOn(.fnLanguage), perApp = c.isOn(.perAppLayout)
        guard fn || perApp else { return DashState(text: "нет включённых фишек", attention: true) }
        if fn {
            guard c.tapActive else { return DashState(text: "не слушаю клавиатуру", attention: true) }
            if let app = c.secureInputApp {
                return DashState(text: "Сейчас Fn не слышно: защищённый ввод в \(app)", attention: true)
            }
            // Второе переключение от системы ломает смену языка: показываем сразу.
            if c.systemUsage != 0 { return DashState(text: "системное действие 🌐 мешает", attention: true) }
        }
        // Включённые фишки коротко; одна — просто текущий язык.
        if fn && perApp { return DashState(text: "\(KeyboardFeature.fnLanguage.shortName) · \(KeyboardFeature.perAppLayout.shortName)") }
        return DashState(text: fn ? c.currentName : "\(KeyboardFeature.perAppLayout.shortName) · \(c.currentName)")
    }

    /// И для встроенного модуля, и для `RemoteAwakeModel`: остаток времени в строку статуса не входит.
    static func awake(_ c: some AwakeModel) -> DashState {
        guard c.isActive else {
            // Как кнопка на экране модуля: включить сейчас нельзя — действия нет.
            return c.canStart ? DashState(text: "можно спать", actionTitle: "Не спать", actionIcon: "cup.and.saucer")
                              : DashState(text: "можно спать")
        }
        let tail = c.endDate.map { " · ещё \(AwakeKeys.remainingText(until: $0))" } ?? ""
        return DashState(text: "не спит\(tail)", actionTitle: "Можно спать", actionIcon: "moon.zzz")
    }

    private static func mixer() -> DashState {
        let apps = MixerController.shared.apps
        guard let first = apps.first else { return DashState(text: "сейчас ничего не играет") }
        let volume = first.volume < 0.995 ? " · \(Int((first.volume * 100).rounded())) %" : ""
        if apps.count == 1 { return DashState(text: "играет \(first.name)\(volume)") }
        return DashState(text: "играют \(first.name) и ещё \(apps.count - 1)")
    }

    private static func bots() -> DashState {
        let state = BotsStore.shared.state
        return DashState(text: BotsText.summary(state), attention: state.file.kind == .unsafe)
    }

    private static func load() -> DashState {
        guard let memory = LoadStore.shared.snapshot?.memory else {
            return DashState(text: "открой для замера", actionTitle: "Обновить")
        }
        return DashState(text: "память \(Fmt.gb(Double(memory.usedMB))) из \(Fmt.gb(Double(memory.totalMB))) ГБ",
                         actionTitle: "Обновить")
    }
}

// MARK: - Страница

struct DashboardPage: View, Equatable {
    static func == (a: Self, b: Self) -> Bool { true }
    /// Открыть модуль в основном окне.
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var access = AccessState.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared
    @Environment(\.dsTheme) private var theme
    @State private var confirmation: DashConfirmation?

    private var shown: [Module] { modules.panelModules }

    var body: some View {
        // В обычном окне всё помещается без прокрутки; в самом маленьком — прокручивается.
        ScrollView(showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { item in
            Button(item.button, role: .destructive) { item.run() }
            Button("Отмена", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 20) {
                section(ModuleCategory.all[0], columns: 2)
                HStack(alignment: .top, spacing: 14) {
                    section(ModuleCategory.all[1], columns: 1)
                    section(ModuleCategory.all[2], columns: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.pagePadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Шапка

    private var header: some View {
        // Выключенная утилита остаётся установленной: в шапке она не «включена», как и на своей карточке.
        let on = shown.filter { modules.isExternal($0) ? satellites.entries[$0]?.status?.enabled ?? true : modules.isOn($0) }
        let needAccess = on.filter { $0.isBlocked }
        return HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.1)).frame(width: 50, height: 50)
                .overlay(Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Дашборд").font(DS.pageTitle)
                HStack(spacing: 6) {
                    Circle().fill(needAccess.isEmpty ? Color(red: 0.50, green: 0.78, blue: 0.58) : .orange)
                        .frame(width: 7, height: 7)
                    Text(summary(on: on.count, of: shown.count, needAccess: needAccess))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }

    private func summary(on: Int, of total: Int, needAccess: [Module]) -> String {
        let count = "\(on) из \(total) \(Fmt.word(total, "модуля", "модулей", "модулей")) \(on == 1 ? "включён" : "включены")"
        if !needAccess.isEmpty {
            return "Нужен доступ: \(needAccess.map(\.title).joined(separator: ", ")) · \(count)"
        }
        return on == 0 ? "Ничего не включено · \(count)" : "Всё работает · \(count)"
    }

    // MARK: Секции

    @ViewBuilder
    private func section(_ category: ModuleCategory, columns: Int) -> some View {
        let items = shown.filter { $0.category == category }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: category.icon).font(.system(size: 11, weight: .semibold))
                    Text(category.title.uppercased()).font(DS.sectionTitle).tracking(0.8)
                }
                .foregroundStyle(theme.categoryColor(category).opacity(0.95))
                .padding(.horizontal, 4)
                if columns == 1 {
                    ForEach(items) { card($0) }
                } else {
                    ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                        HStack(spacing: 8) {
                            ForEach(0..<columns, id: \.self) { offset in
                                if start + offset < items.count {
                                    card(items[start + offset])
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func card(_ module: Module) -> some View {
        DashCard(module: module, open: { open(module) }, ask: { confirmation = $0 })
    }
}

// MARK: - Карточки

private let dashCardHeight: CGFloat = 64

private struct DashCard: View {
    let module: Module
    let open: () -> Void
    let ask: (DashConfirmation) -> Void
    /// Карточка наблюдает только статус своего модуля.
    @ObservedObject private var slot: DashSlot
    @Environment(\.dsTheme) private var theme

    init(module: Module, open: @escaping () -> Void, ask: @escaping (DashConfirmation) -> Void) {
        self.module = module
        self.open = open
        self.ask = ask
        slot = DashboardLive.slot(module)
    }

    var body: some View {
        let state = slot.state
        let on = state.on
        let tint = theme.tone(module)
        HStack(spacing: 11) {
            HStack(spacing: 11) {
                ModuleIconBadge(module: module, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(state.text)
                        .font(.system(size: 12))
                        .foregroundStyle(state.attention ? Color.orange : .white.opacity(0.55))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .opacity(on ? 1 : 0.45)
            Spacer(minLength: 4)
            if !on {
                DashButton(title: "Включить", solid: true, tint: tint) { DashboardLive.setOn(module, true) }
            } else if let title = state.actionTitle {
                DashButton(title: title, icon: state.actionIcon, tint: tint) {
                    DashboardLive.perform(module, ask: ask)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: dashCardHeight)
        .hoverFill(RoundedRectangle(cornerRadius: 14, style: .continuous),
                   normal: tint.opacity(0.075), hovered: tint.opacity(on ? 0.13 : 0.075))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.2), lineWidth: 0.7))
        .onTapGesture(perform: open)
        .contextMenu {
            Button(on ? "Выключить модуль" : "Включить модуль") { DashboardLive.setOn(module, !on) }
            Button("Открыть", action: open)
        }
        .accessibilityElement(children: .contain)
        .onPageActive { if $0 { slot.attach() } else { slot.detach() } }
    }
}

/// Кнопка карточки: залитая («Включить») или мягкая. Подсветка при наведении мгновенная.
private struct DashButton: View {
    let title: String
    var icon: String?
    var solid = false
    let tint: Color
    let action: () -> Void
    @Environment(\.dsTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(solid ? theme.onAccent : tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .hoverFill(Capsule(), normal: tint.opacity(solid ? 0.92 : 0.18), hovered: tint.opacity(solid ? 1 : 0.28))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
