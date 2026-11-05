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

/// Что показать у модуля: строка статуса и название быстрого действия. Сравнивается целиком,
/// поэтому неизменный статус никого не перерисовывает. Само действие — `DashboardLive.perform`.
struct DashState: Equatable {
    var on = true
    var text = ""
    /// Нужно внимание (нет доступа, не хватает модели): строка оранжевая.
    var attention = false
    var actionTitle: String?
    var actionIcon: String?
}

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
        let visible = NSApp.map { app in
            !app.isHidden && app.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        } ?? true
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

    private func stop() {
        subs = []
        sourceSub = nil
    }

    private func reconcile() {
        guard attached > 0, WindowVisibility.shared.isVisible else { stop(); return }
        if subs.isEmpty {
            // willChange приходит до смены значения: читаем контроллер со следующего витка.
            subs = [
                ModuleManager.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() },
                AccessState.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() },
            ]
        }
        update()
    }

    /// Выключенный модуль ничего не публикует: на контроллер подписываемся, только пока он включён.
    private func syncSource() {
        if ModuleManager.shared.isOn(module) {
            guard sourceSub == nil else { return }
            // Не чаще раза в секунду: вентиляторы публикуют каждые 2 с.
            sourceSub = DashboardLive.source(module)
                .receive(on: DispatchQueue.main)
                .throttle(for: 1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in self?.update() }
        } else {
            sourceSub = nil
        }
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

    fileprivate static func source(_ module: Module) -> AnyPublisher<Void, Never> {
        switch module {
        case .sound: return MonitorState.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .mouse: return MouseController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .fans: return FanController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .browser: return BrowserCatalog.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .stash: return StashStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .voice: return VoiceController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .mixer: return MixerController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .load: return LoadStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        }
    }

    /// Быстрое действие карточки. `askStash` — показать подтверждение «Закрыть N программ?».
    static func perform(_ module: Module, askStash: () -> Void) {
        switch module {
        case .fans:
            FanController.shared.fullPower.toggle()
        case .browser:
            // Тестовая ссылка идёт тем же путём, что и кнопка «Проверить» на экране браузера.
            NSWorkspace.shared.open([BrowserHelper.testURL], withApplicationAt: BrowserHelper.appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Utilitumus: помощник ссылок не запустился: %@", error.localizedDescription) }
            }
        case .stash:
            let store = StashStore.shared
            if !store.stashed.isEmpty {
                Task { await store.restore() }
            } else {
                // Закрытие программ — только через подтверждение, как на экране Стеша.
                askStash()
            }
        case .load:
            LoadStore.shared.refreshNow()
        case .sound, .mouse, .voice, .mixer:
            break
        }
    }

    fileprivate static func compute(_ module: Module) -> DashState {
        guard ModuleManager.shared.isOn(module) else { return DashState(on: false, text: "выключен") }
        if module.isBlocked { return DashState(text: "нужен доступ", attention: true) }
        switch module {
        case .sound: return sound()
        case .mouse: return mouse()
        case .fans: return fans()
        case .browser: return browser()
        case .stash: return stash()
        case .voice: return voice()
        case .mixer: return mixer()
        case .load: return load()
        }
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
        if FanHelperInstaller.shared.status != .notInstalled && c.conflictingApp == nil {
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

    private static func mixer() -> DashState {
        let apps = MixerController.shared.apps
        guard let first = apps.first else { return DashState(text: "сейчас ничего не играет") }
        let volume = first.volume < 0.995 ? " · \(Int((first.volume * 100).rounded())) %" : ""
        if apps.count == 1 { return DashState(text: "играет \(first.name)\(volume)") }
        return DashState(text: "играют \(first.name) и ещё \(apps.count - 1)")
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
    @Environment(\.pageActive) private var pageActive
    /// Открыть модуль в основном окне.
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var access = AccessState.shared
    @Environment(\.dsTheme) private var theme
    @State private var confirmStash = false

    private var shown: [Module] { modules.shownModules }

    var body: some View {
        // В обычном окне всё помещается без прокрутки; в самом маленьком — прокручивается.
        ScrollView(showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog("Закрыть \(programs(StashStore.shared.selected.count))?", isPresented: $confirmStash) {
            Button("Закрыть и спрятать", role: .destructive) {
                Task { await StashStore.shared.stashSelected() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(StashStore.shared.selected.compactMap(\.localizedName).joined(separator: ", ")
                 + "\n\nНесохранённое программы спросят сами.")
        }
        // Список программ для Стеша: один разовый снимок, без подписок. Само не запускается.
        .task(id: pageActive) {
            guard pageActive, modules.isOn(.stash) else { return }
            StashStore.shared.refresh()
            await StashStore.shared.refreshUsage()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 20) {
                section(ModuleCategory.all[0], columns: 2)
                HStack(alignment: .top, spacing: 14) {
                    section(ModuleCategory.all[1], columns: 1)
                    section(ModuleCategory.all[2], columns: 1, soon: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.pagePadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Шапка

    private var header: some View {
        let on = shown.filter { modules.isOn($0) }
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
    private func section(_ category: ModuleCategory, columns: Int, soon: Bool = false) -> some View {
        let items = shown.filter { $0.category == category }
        if !items.isEmpty || soon {
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
                if soon { DashSoonCard() }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func card(_ module: Module) -> some View {
        DashCard(module: module, open: { open(module) }, askStash: { confirmStash = true })
    }
}

// MARK: - Карточки

private let dashCardHeight: CGFloat = 64

private struct DashCard: View {
    let module: Module
    let open: () -> Void
    let askStash: () -> Void
    /// Карточка наблюдает только статус своего модуля.
    @ObservedObject private var slot: DashSlot
    @Environment(\.dsTheme) private var theme

    init(module: Module, open: @escaping () -> Void, askStash: @escaping () -> Void) {
        self.module = module
        self.open = open
        self.askStash = askStash
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
                DashButton(title: "Включить", solid: true, tint: tint) { ModuleManager.shared.setOn(module, true) }
            } else if let title = state.actionTitle {
                DashButton(title: title, icon: state.actionIcon, tint: tint) {
                    DashboardLive.perform(module, askStash: askStash)
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
            Button(on ? "Выключить модуль" : "Включить модуль") { ModuleManager.shared.setOn(module, !on) }
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

/// «Агент-центр · скоро» — серая заглушка в «С ИИ».
private struct DashSoonCard: View {
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)).frame(width: 34, height: 34)
                .overlay(Image(systemName: "person.3.sequence.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Агент-центр").font(.system(size: 13.5, weight: .semibold))
                Text("общий пульт агентов").font(.system(size: 12))
            }
            Spacer(minLength: 4)
            Text("скоро").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.07)))
        }
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: dashCardHeight)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])))
    }
}
