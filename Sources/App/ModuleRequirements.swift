import SwiftUI
import AVFoundation
import ApplicationServices

/// Что модулю нужно от системы до работы: доступ, разрешение, помощник.
/// Описание живёт здесь, а не в экранах модулей: по нему рисуются «Понадобится» на экране выключенного
/// модуля и экран «Осталось дать доступ» у включённого.
struct ModuleRequirement: Identifiable {
    enum Level {
        /// Без этого модуль не работает: вместо экрана модуля показывается «Осталось дать доступ».
        case required
        /// Модуль работает и без этого, но хуже. Экран доступа показывается, пока не выдано или не нажато «Пропустить».
        case recommended
        /// Заранее проверить нельзя: система спросит сама, когда понадобится. Модуль не блокируется.
        case onFirstUse
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    var level: Level = .required
    var buttonTitle = "Разрешить…"
    let isGranted: @MainActor () -> Bool
    let request: @MainActor () -> Void
    /// Ошибка последней попытки выдать доступ (если есть), показывается под строкой.
    var lastError: @MainActor () -> String? = { nil }

    /// Нужно ли показать экран доступа из-за этого пункта.
    @MainActor var isBlocking: Bool {
        switch level {
        case .required: return !isGranted()
        case .recommended: return !isGranted() && !ModuleRequirement.isSkipped(id)
        case .onFirstUse: return false
        }
    }

    private static let skippedKey = "Requirements.Skipped"

    static func isSkipped(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: skippedKey) ?? []).contains(id)
    }

    static func skip(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: skippedKey) ?? []
        if !ids.contains(id) { ids.append(id) }
        UserDefaults.standard.set(ids, forKey: skippedKey)
    }

    /// «Универсальный доступ»: у «Стеша», «Мыши» и «Голоса» один и тот же пункт, запрос — свой у каждого контроллера.
    @MainActor static func accessibility(id: String, subtitle: String, level: Level = .required,
                                         request: @escaping @MainActor () -> Void) -> ModuleRequirement {
        ModuleRequirement(id: id, title: "Универсальный доступ", subtitle: subtitle, icon: "lock.shield.fill",
                          level: level, isGranted: { AXIsProcessTrusted() }, request: request)
    }
}

extension Module {
    @MainActor var requirements: [ModuleRequirement] {
        switch self {
        case .sound, .load, .browser:
            return []
        case .fans:
            return [ModuleRequirement(
                id: "fans.helper", title: "Помощник для вентиляторов", subtitle: "Пароль администратора, один раз",
                icon: "key.fill", buttonTitle: "Дать доступ…",
                // Устаревший помощник ещё работает: обновить его можно с экрана модуля.
                isGranted: { FanHelperInstaller.shared.status != .notInstalled },
                request: { FanHelperInstaller.shared.install() },
                lastError: { FanHelperInstaller.shared.lastError })]
        case .stash:
            return [.accessibility(id: "stash.ax", subtitle: "Чтобы вернуть окна на места",
                                   request: { StashStore.shared.requestAccess() })]
        case .mouse:
            return [.accessibility(id: "mouse.ax", subtitle: "Чтобы менять направление и плавность прокрутки",
                                   request: { MouseController.shared.requestAccess() })]
        case .mixer:
            return [ModuleRequirement(
                id: "mixer.capture", title: "Запись системного звука", subtitle: "Система спросит при первом звуке",
                icon: "waveform.badge.mic", level: .onFirstUse,
                isGranted: { !MixerController.shared.permissionProblem },
                request: {})]
        case .voice:
            return [
                ModuleRequirement(
                    id: "voice.mic", title: "Микрофон", subtitle: "Чтобы слышать тебя; звук остаётся на этом Mac",
                    icon: "mic.fill",
                    isGranted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                    request: { VoiceController.shared.requestMic() }),
                .accessibility(id: "voice.ax", subtitle: "Чтобы текст вставлялся сам, иначе останется нажать ⌘V",
                               level: .recommended, request: { VoiceController.shared.requestAccessibility() }),
            ]
        }
    }

    /// Пункты, из-за которых вместо экрана модуля показывается «Осталось дать доступ».
    @MainActor var blockingRequirements: [ModuleRequirement] { requirements.filter(\.isBlocking) }
}

// MARK: - Экран «Осталось дать доступ»

/// Модуль включён, но не хватает доступа. Статусы обновляются раз в 1,5 с, пока экран открыт,
/// и при возвращении в приложение из настроек. Как только всё выдано, `onChange` просит `ModuleScreen`
/// показать сам модуль.
struct ModuleSetupView: View {
    let module: Module
    let onChange: () -> Void
    /// Подмена списка нужна только для предпросмотра экрана; в приложении берётся `module.requirements`.
    var requirements: [ModuleRequirement]?
    @Environment(\.dsTheme) private var theme
    @State private var tick = 0

    private var items: [ModuleRequirement] { requirements ?? module.requirements }

    var body: some View {
        let _ = tick
        let shown = items.filter { $0.level != .onFirstUse }
        let blocking = items.filter(\.isBlocking)
        let onlyRecommendedLeft = !blocking.isEmpty && blocking.allSatisfy { $0.level == .recommended }
        return ModuleCentered(module: module, title: "Осталось дать доступ",
                              lead: "Без этого «\(module.title)» не заработает как надо. Экран обновится сам, когда всё будет выдано.") {
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    ModuleRequirementRow(requirement: item, onRequest: {
                        item.request()
                        refresh()
                    })
                }
            }
            .modifier(ModuleCard())
        } actions: {
            if onlyRecommendedLeft {
                DSButton("Пропустить", icon: "forward.end.fill", style: .primary) {
                    items.filter { $0.level == .recommended }.forEach { ModuleRequirement.skip($0.id) }
                    onChange()
                }
            }
            DSButton("Подробнее", icon: "info.circle", style: .plain) { ModuleManager.shared.infoModule = module }
        }
        .environment(\.dsTint, theme.accent(module))
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        if module == .fans { FanHelperInstaller.shared.refresh() }
        tick += 1
        if !items.contains(where: \.isBlocking) { onChange() }
    }
}

/// Строка требования: значок, название, пояснение, справа галочка или кнопка. Ошибка попытки — под строкой.
struct ModuleRequirementRow: View {
    let requirement: ModuleRequirement
    var onRequest: (() -> Void)?
    /// Без значка и с короткими строками: для узкой колонки на экране выключенного модуля.
    var compact = false
    @Environment(\.dsTint) private var tint

    var body: some View {
        let granted = requirement.isGranted()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if !compact {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: requirement.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(requirement.title).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(compact ? 2 : 1)
                        if requirement.level == .recommended && !compact { DSChip("желательно", color: .secondary) }
                    }
                    Text((compact && requirement.level == .recommended ? "Желательно: " : "") + requirement.subtitle).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                if let onRequest {
                    if granted {
                        DSChip("Выдано", color: .green, icon: "checkmark")
                    } else {
                        DSButton(requirement.buttonTitle, style: requirement.level == .required ? .primary : .secondary,
                                 small: true, action: onRequest)
                    }
                } else if granted && requirement.level != .onFirstUse {
                    DSChip("Выдано", color: .green, icon: "checkmark")
                }
            }
            if !granted, let error = requirement.lastError() {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).padding(.top, 4).padding(.leading, compact ? 0 : 42)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, compact ? 14 : 56)
        }
    }
}

// MARK: - Общая вёрстка центрированных экранов

/// Карточка группы (как у `DSSection`), для содержимого экранов «выключен» и «доступ».
struct ModuleCard: ViewModifier {
    @Environment(\.dsTheme) private var theme
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -1)
            .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
            .clipShape(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.7))
    }
}

/// Экран по центру страницы: большой значок модуля, название, абзац, блок содержимого, кнопки.
struct ModuleCentered<Body: View, Actions: View>: View {
    let module: Module
    let title: String
    let lead: String
    @ViewBuilder var body_: Body
    @ViewBuilder var actions: Actions

    init(module: Module, title: String, lead: String,
         @ViewBuilder body: () -> Body, @ViewBuilder actions: () -> Actions) {
        self.module = module
        self.title = title
        self.lead = lead
        self.body_ = body()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                ModuleIconBadge(module: module, size: 84)
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title).font(DS.pageTitle)
                    Text(lead)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                }
                body_
                    .frame(maxWidth: 640)
                    .padding(.top, 4)
                HStack(spacing: 10) { actions }
                    .padding(.top, 2)
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
