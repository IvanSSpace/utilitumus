import SwiftUI
import AppKit
import Combine

// Дашборд: страница по умолчанию. Три секции по категориям, у каждого модуля — живой статус
// и одно быстрое действие. Статус приходит от утилиты: центр сам ничего не меряет и не запускает.
//
// Статус модуля — отдельный `DashSlot`: он подписывается на модель утилиты, пока статус на экране (карточка
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

    /// Модель, у которой включено слежение за дашбордом: снять его надо у неё же, даже если утилиты уже нет.
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
            // willChange приходит до смены значения: читаем состояние со следующего витка.
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
        guard let source = DashboardLive.source(module) else {
            sourceSub = nil
            return
        }
        guard sourceSub == nil else { return }
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

/// Реестр статусов модулей.
@MainActor
enum DashboardLive {
    private static let slots: [Module: DashSlot] = Dictionary(
        uniqueKeysWithValues: Module.allCases.map { ($0, DashSlot($0)) })

    static func slot(_ module: Module) -> DashSlot { slots[module]! }

    /// Как при открытии вкладки: пока статус не был на экране, утилита могла зависнуть.
    fileprivate static func refreshExternal(_ module: Module) {
        guard ModuleManager.shared.isExternal(module) else { return }
        if let model = RemoteModules.model(module) { model.refresh() } else { SatelliteRegistry.shared.refresh(module) }
    }

    /// Что слушать, пока модуль на экране: его модель, если она есть (`RemoteModules`). Статус слушает реестр.
    fileprivate static func source(_ module: Module) -> AnyPublisher<Void, Never>? {
        ModuleManager.shared.isExternal(module) ? RemoteModules.model(module)?.changes : nil
    }

    /// Быстрое действие карточки. `ask` — показать подтверждение, если оно нужно.
    static func perform(_ module: Module, ask: (DashConfirmation) -> Void) {
        if ModuleManager.shared.isExternal(module) { performExternal(module, ask: ask) }
    }

    /// Переключатель на карточке модуля с утилитой: она выключается у себя. Без утилиты переключать нечего.
    static func setOn(_ module: Module, _ on: Bool) {
        SatelliteRegistry.shared.setEnabled(module, on)
    }

    /// Состояние карточки сейчас, без подписки: поднятая при перетаскивании строка панели не должна заводить слот.
    static func snapshot(_ module: Module) -> DashState { compute(module) }

    fileprivate static func compute(_ module: Module) -> DashState {
        guard ModuleManager.shared.isExternal(module) else { return missingState }
        return externalState(status: SatelliteRegistry.shared.entries[module]?.status,
                             model: RemoteModules.model(module))
    }

    /// Карточка модуля без утилиты. Действия нет, включать нечего: клик ведёт на его страницу, а там кнопка «Установить».
    static let missingState = DashState(text: "утилита не установлена", attention: true)

    /// Карточка модуля из статуса утилиты: выключен, нужен доступ, оранжевое, действие.
    /// Чистая функция: проверка не нуждается ни в утилите, ни в центре.
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

    /// Карточка `RemoteAwakeModel`: остаток времени в строку статуса не входит.
    static func awake(_ c: some AwakeModel) -> DashState {
        guard c.isActive else {
            // Как кнопка на экране модуля: включить сейчас нельзя — действия нет.
            return c.canStart ? DashState(text: "можно спать", actionTitle: "Не спать", actionIcon: "cup.and.saucer")
                              : DashState(text: "можно спать")
        }
        let tail = c.endDate.map { " · ещё \(AwakeKeys.remainingText(until: $0))" } ?? ""
        return DashState(text: "не спит\(tail)", actionTitle: "Можно спать", actionIcon: "moon.zzz")
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
        let on = shown.filter { modules.isExternal($0) && satellites.entries[$0]?.status?.enabled ?? true }
        let needAccess = on.filter { $0.isBlocked }
        let missing = shown.filter { !modules.isExternal($0) }
        return HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.1)).frame(width: 50, height: 50)
                .overlay(Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Дашборд").font(DS.pageTitle)
                HStack(spacing: 6) {
                    Circle().fill(needAccess.isEmpty && missing.isEmpty ? Color(red: 0.50, green: 0.78, blue: 0.58) : .orange)
                        .frame(width: 7, height: 7)
                    Text(Self.summary(on: on.count, of: shown.count, needAccess: needAccess, missing: missing))
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }

    static func summary(on: Int, of total: Int, needAccess: [Module], missing: [Module]) -> String {
        let count = "\(on) из \(total) \(Fmt.word(total, "модуля", "модулей", "модулей")) \(on == 1 ? "включён" : "включены")"
        let access = needAccess.isEmpty ? nil : "Нужен доступ: \(needAccess.map(\.title).joined(separator: ", "))"
        let utility = missing.isEmpty ? nil : "Нет утилиты: \(missing.map(\.title).joined(separator: ", "))"
        let problems = [access, utility].compactMap { $0 }
        if !problems.isEmpty { return (problems + [count]).joined(separator: " · ") }
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
            if ModuleManager.shared.isExternal(module) {
                Button(on ? "Выключить модуль" : "Включить модуль") { DashboardLive.setOn(module, !on) }
            }
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
