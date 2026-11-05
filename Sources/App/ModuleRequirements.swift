import SwiftUI
import Combine

extension Module {
    /// Закешированный ответ «не хватает обязательного шага»: в `body` только чтение, без опроса системы.
    @MainActor var isBlocked: Bool { AccessState.shared.blocked.contains(self) }
}

/// Кеш «не хватает обязательного шага настройки». Систему опрашиваем по событиям: возврат в приложение, ответ помощника
/// вентиляторов, действия на экране доступа. Публикуем только при реальной смене.
@MainActor
final class AccessState: ObservableObject {
    static let shared = AccessState()

    @Published private(set) var blocked: Set<Module> = []
    private var subs: [AnyCancellable] = []

    private init() {
        blocked = Self.compute()
        subs.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                FanHelperInstaller.shared.refresh()
                self?.refresh()
            })
        // Установка помощника кончается асинхронно: willChange приходит до смены значения, читаем со следующего витка.
        subs.append(FanHelperInstaller.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() })
    }

    func refresh() {
        let new = Self.compute()
        if new != blocked { blocked = new }
    }

    private static func compute() -> Set<Module> {
        Set(Module.allCases.filter { !$0.setupProgress.requiredDone })
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
