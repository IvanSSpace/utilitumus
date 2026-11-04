import SwiftUI
import AppKit
import Combine

// Дашборд: страница по умолчанию. Три секции по категориям, у каждого модуля — живой статус
// и одно быстрое действие. Статусы читаются из настоящих контроллеров только у включённых модулей
// и ничего не запускают: ни таймеров, ни подписок на систему. Подписка на изменения — на уже
// существующие `objectWillChange`, и только у включённых.

// MARK: - Живые статусы

/// Быстрое действие на карточке модуля.
struct DashAction {
    let title: String
    var icon: String?
    let run: () -> Void
}

/// Что показать у включённого модуля: строка статуса и быстрое действие.
struct DashLive {
    var text: String
    /// Нужно внимание (нет доступа, не хватает модели): строка оранжевая.
    var attention = false
    var action: DashAction?
}

/// Собирает статусы модулей из контроллеров и сообщает, когда они поменялись.
/// Контроллер выключенного модуля не читается и не трогается.
@MainActor
final class DashboardLive: ObservableObject {
    static let shared = DashboardLive()

    private let modules = ModuleManager.shared
    private var managerSub: AnyCancellable?
    private var subs: [Module: AnyCancellable] = [:]

    private init() {
        managerSub = modules.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resubscribe() }
        resubscribe()
    }

    /// Подписки — только у включённых модулей: выключенный ничего не публикует.
    private func resubscribe() {
        for module in Module.allCases {
            if modules.isOn(module) {
                if subs[module] == nil { subs[module] = publisher(module).sink { [weak self] in self?.objectWillChange.send() } }
            } else {
                subs[module] = nil
            }
        }
        objectWillChange.send()
    }

    /// Не чаще раза в секунду: вентиляторы публикуют каждые 2 с, перерисовывать панель чаще незачем.
    private func publisher(_ module: Module) -> AnyPublisher<Void, Never> {
        let source: AnyPublisher<Void, Never>
        switch module {
        case .sound: source = MonitorState.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .mouse: source = MouseController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .fans: source = FanController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .browser: source = BrowserCatalog.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .stash: source = StashStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .voice: source = VoiceController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .mixer: source = MixerController.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        case .load: source = LoadStore.shared.objectWillChange.map { _ in }.eraseToAnyPublisher()
        }
        return source.throttle(for: 1, scheduler: DispatchQueue.main, latest: true).eraseToAnyPublisher()
    }

    /// Строка под названием модуля в боковой панели.
    func rowText(_ module: Module) -> (text: String, attention: Bool) {
        guard modules.isOn(module) else { return ("выключен", false) }
        let state = live(module, askStash: {})
        return (state.text, state.attention)
    }

    /// Статус и действие включённого модуля. `askStash` — показать подтверждение «Закрыть N программ?».
    func live(_ module: Module, askStash: @escaping () -> Void) -> DashLive {
        if !module.blockingRequirements.isEmpty { return DashLive(text: "нужен доступ", attention: true) }
        switch module {
        case .sound: return sound()
        case .mouse: return mouse()
        case .fans: return fans()
        case .browser: return browser()
        case .stash: return stash(askStash)
        case .voice: return voice()
        case .mixer: return mixer()
        case .load: return load()
        }
    }

    private func sound() -> DashLive {
        let name = MonitorState.shared.currentInputName
        return DashLive(text: name == "—" ? "слежу за микрофоном" : name)
    }

    private func mouse() -> DashLive {
        let s = MouseController.shared.settings
        guard s.needsTap else { return DashLive(text: "всё как в системе") }
        var parts: [String] = []
        if s.mouseDirection == .reversed || s.magicMouseDirection == .reversed { parts.append("прокрутка обратная") }
        if s.smoothEnabled { parts.append("плавность \(Int((s.smoothness * 100).rounded())) %") }
        return DashLive(text: parts.joined(separator: " · "))
    }

    private func fans() -> DashLive {
        let c = FanController.shared
        if c.safetyTripped { return DashLive(text: "перегрев · вентиляторами управляет система", attention: true) }
        var parts: [String] = []
        if let t = c.cpuMax { parts.append("\(Int(t.rounded()))°") }
        if c.fullPower {
            parts.append("Макс")
        } else {
            let modes = Set(c.configs.map(\.mode))
            parts.append(modes.count > 1 ? "Разные режимы" : (modes.first ?? .auto).title)
        }
        if let rpm = c.fans.map(\.actual).max() { parts.append("\(Int(rpm.rounded())) об/мин") }
        // Без доступа помощника кнопка ничего бы не сделала.
        var action: DashAction?
        if FanHelperInstaller.shared.status != .notInstalled && c.conflictingApp == nil {
            action = c.fullPower
                ? DashAction(title: "Авто", icon: "arrow.uturn.backward") { c.fullPower = false }
                : DashAction(title: "Максимум", icon: "wind") { c.fullPower = true }
        }
        return DashLive(text: parts.joined(separator: " · "), action: action)
    }

    private func browser() -> DashLive {
        let catalog = BrowserCatalog.shared
        let text: String
        if let main = catalog.fallback {
            text = "основной: \(main.name)"
        } else {
            text = catalog.browsers.isEmpty ? "ищу браузеры…" : "основной не выбран"
        }
        // Тестовая ссылка идёт тем же путём, что и кнопка «Проверить» на экране браузера.
        return DashLive(text: text, action: DashAction(title: "Проверить") {
            NSWorkspace.shared.open([BrowserHelper.testURL], withApplicationAt: BrowserHelper.appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Utilitumus: помощник ссылок не запустился: %@", error.localizedDescription) }
            }
        })
    }

    private func stash(_ ask: @escaping () -> Void) -> DashLive {
        let store = StashStore.shared
        if !store.stashed.isEmpty {
            return DashLive(text: "спрятано \(store.stashed.count) · можно вернуть",
                            action: DashAction(title: "Вернуть", icon: "arrow.uturn.backward") {
                                Task { await store.restore() }
                            })
        }
        if let busy = store.busy { return DashLive(text: busy) }
        let selected = store.selected
        guard !selected.isEmpty else { return DashLive(text: "нет программ для закрытия") }
        let freed = selected.reduce(0.0) { $0 + (store.usage[$1.bundleIdentifier ?? ""]?.memoryMB ?? 0) }
        let tail = freed > 0 ? " · ≈ \(memoryText(freed))" : ""
        // Закрытие программ — только через подтверждение, как на экране Стеша.
        return DashLive(text: "выбрано \(selected.count)\(tail)",
                        action: DashAction(title: "Спрятать", icon: "archivebox", run: ask))
    }

    private func voice() -> DashLive {
        let controller = VoiceController.shared
        let models = VoiceModelStore.shared
        if controller.phase == .recording { return DashLive(text: "идёт запись…") }
        let model = models.selected.title.components(separatedBy: " — ")[0]
        if models.status(models.selected) != .installed {
            return DashLive(text: "\(controller.hotKeyLabel) · модель не скачана", attention: true)
        }
        return DashLive(text: "\(controller.hotKeyLabel) · \(model)")
    }

    private func mixer() -> DashLive {
        let apps = MixerController.shared.apps
        guard let first = apps.first else { return DashLive(text: "сейчас ничего не играет") }
        let volume = first.volume < 0.995 ? " · \(Int((first.volume * 100).rounded())) %" : ""
        if apps.count == 1 { return DashLive(text: "играет \(first.name)\(volume)") }
        return DashLive(text: "играют \(first.name) и ещё \(apps.count - 1)")
    }

    private func load() -> DashLive {
        let store = LoadStore.shared
        let refresh = DashAction(title: "Обновить") { store.refreshNow() }
        guard let memory = store.snapshot?.memory else {
            return DashLive(text: "открой для замера", action: refresh)
        }
        return DashLive(text: "память \(Fmt.gb(Double(memory.usedMB))) из \(Fmt.gb(Double(memory.totalMB))) ГБ",
                        action: refresh)
    }
}

// MARK: - Страница

struct DashboardPage: View {
    /// Открыть модуль в основном окне.
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var live = DashboardLive.shared
    @Environment(\.dsTheme) private var theme
    @State private var confirmStash = false

    private var shown: [Module] { modules.shownModules }

    var body: some View {
        // В обычном окне всё помещается без прокрутки; в самом маленьком — прокручивается.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(showsIndicators: false) { content }
        }
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
        .task {
            guard modules.isOn(.stash) else { return }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Шапка

    private var header: some View {
        let on = shown.filter { modules.isOn($0) }
        let needAccess = on.filter { !$0.blockingRequirements.isEmpty }
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
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var live = DashboardLive.shared
    @Environment(\.dsTheme) private var theme
    @State private var hover = false

    var body: some View {
        let on = modules.isOn(module)
        let state = on ? live.live(module, askStash: askStash) : nil
        let tint = theme.tone(module)
        HStack(spacing: 11) {
            HStack(spacing: 11) {
                ModuleIconBadge(module: module, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(state?.text ?? "выключен")
                        .font(.system(size: 12))
                        .foregroundStyle(state?.attention == true ? Color.orange : .white.opacity(0.55))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .opacity(on ? 1 : 0.45)
            Spacer(minLength: 4)
            if !on {
                DashButton(title: "Включить", solid: true, tint: tint) { modules.setOn(module, true) }
            } else if let action = state?.action {
                DashButton(title: action.title, icon: action.icon, tint: tint, action: action.run)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: dashCardHeight)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.opacity(hover && on ? 0.13 : 0.075)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.2), lineWidth: 0.7))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.2), value: hover)
        .onTapGesture(perform: open)
        .contextMenu {
            Button(on ? "Выключить модуль" : "Включить модуль") { modules.setOn(module, !on) }
            Button("Открыть", action: open)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Кнопка карточки: залитая («Включить») или мягкая.
private struct DashButton: View {
    let title: String
    var icon: String?
    var solid = false
    let tint: Color
    let action: () -> Void
    @Environment(\.dsTheme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(solid ? theme.onAccent : tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(solid ? AnyShapeStyle(tint.opacity(hover ? 1 : 0.92))
                                             : AnyShapeStyle(tint.opacity(hover ? 0.28 : 0.18))))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.2), value: hover)
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
