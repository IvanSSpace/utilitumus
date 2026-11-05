import SwiftUI

// Экраны настройки модуля: чек-лист (на весь экран модуля), плашка «Настройка: 2 из 3» над ним,
// строка шага (в чек-листе и в компактном виде — в «Понадобится» и в подробностях Стора).

// MARK: - Чек-лист

/// «Чтобы «Клавиатура» заработала: 2 из 3». Статусы опрашиваются раз в секунду, пока чек-лист на экране
/// и страница активна: выдал доступ в настройках — шаг сам станет готовым, без перезапуска.
struct SetupChecklistView: View {
    @Environment(\.pageActive) private var pageActive
    @Environment(\.dsTheme) private var theme
    @ObservedObject private var flow = SetupFlow.shared
    let module: Module
    /// Слепок статусов: перерисовка только при реальной смене.
    @State private var snapshot: [String] = []

    private func makeSnapshot() -> [String] {
        module.setupSteps.map { "\($0.id):\($0.status):\($0.busy() ?? ""):\($0.lastError() ?? "")" }
    }

    var body: some View {
        let _ = snapshot
        let progress = module.setupProgress
        let nextID = progress.requiredMissing.first?.id
        let ready = progress.requiredDone
        return ModuleCentered(
            module: module,
            title: "Чтобы «\(module.title)» заработала: \(progress.done) из \(progress.total)",
            lead: ready
                ? "Всё нужное есть. Необязательное можно сделать сейчас или потом."
                : "Шаги по порядку. Экран обновится сам, когда шаг будет сделан.") {
            VStack(spacing: 0) {
                let visible = Array(zip(progress.steps, progress.statuses))
                ForEach(Array(visible.enumerated()), id: \.element.0.id) { index, pair in
                    SetupStepRow(step: pair.0, status: pair.1, number: index + 1, isNext: pair.0.id == nextID) {
                        pair.0.perform()
                        refresh()
                    }
                }
            }
            .modifier(ModuleCard())
        } actions: {
            if ready {
                DSButton("Готово, можно пользоваться", icon: "checkmark", style: .primary) { flow.finish(module) }
            } else {
                if progress.steps.contains(where: { $0.isAutomatic || $0.kind == .permission }) {
                    DSButton("Сделать всё автоматически", icon: "wand.and.stars", style: .primary) {
                        flow.doAll(module)
                        refresh()
                    }
                }
                DSButton("Позже", style: .secondary) { flow.postpone(module) }
            }
            DSButton("Подробнее", icon: "info.circle", style: .plain) { ModuleManager.shared.infoModule = module }
        }
        .environment(\.dsTint, theme.accent(module))
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if pageActive { refresh() }
        }
        // Опрос только пока чек-лист на экране: .task снимается вместе с видом, а скрытая страница не опрашивает.
        .task(id: pageActive) {
            guard pageActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                refresh()
            }
        }
    }

    private func refresh() {
        module.refreshSetupSources()
        let new = makeSnapshot()
        if new != snapshot { snapshot = new }
        AccessState.shared.refresh()
    }
}

// MARK: - Строка шага

/// Номер или галочка, название, «зачем», справа кнопка действия или «Готово». Ошибка попытки — под строкой.
struct SetupStepRow: View {
    let step: SetupStep
    let status: SetupStep.Status
    var number: Int?
    /// Первый невыполненный обязательный шаг: его кнопка главная.
    var isNext = false
    /// Без кнопок и номеров, для узких колонок («Понадобится», подробности Стора).
    var compact = false
    var onPerform: (() -> Void)?
    @Environment(\.dsTint) private var tint

    var body: some View {
        let done = status == .done
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if !compact { marker(done: done) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(step.title).font(DS.rowTitle).foregroundStyle(.white.opacity(done ? 0.6 : 0.95))
                            .lineLimit(compact ? 2 : 1)
                        if status == .optional && !compact { DSChip("необязательно", color: .secondary) }
                    }
                    Text(step.busy() ?? step.why).font(DS.rowSubtitle)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                trailing(done: done)
            }
            if !done, let error = step.lastError() {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).padding(.top, 4).padding(.leading, compact ? 0 : 38)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14)
        }
    }

    @ViewBuilder
    private func marker(done: Bool) -> some View {
        ZStack {
            Circle().fill(done ? Color.green.opacity(0.2) : tint.opacity(0.18)).frame(width: 26, height: 26)
            if done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
            } else {
                Text("\(number ?? 0)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(tint)
            }
        }
    }

    @ViewBuilder
    private func trailing(done: Bool) -> some View {
        if done {
            DSChip("Готово", color: .green, icon: "checkmark")
        } else if status == .onDemand {
            DSChip("спросит сама", color: .secondary)
        } else if compact {
            DSChip(step.isAutomatic ? "сделаем сами" : (status == .optional ? "желательно" : "нужно"),
                   color: status == .optional ? .secondary : .orange)
        } else if let onPerform {
            DSButton(step.buttonTitle, style: isNext ? .primary : .secondary, small: true, action: onPerform)
                .disabled(step.busy() != nil)
        }
    }
}

// MARK: - Плашка на экране модуля

/// «Настройка: 2 из 3 — Продолжить», пока что-то не готово, включая необязательное.
/// Если остались только необязательные шаги, плашку можно скрыть. Таймера нет: статус читается
/// при показе страницы и при возврате в приложение.
struct SetupBanner: View {
    @Environment(\.pageActive) private var pageActive
    @Environment(\.dsTheme) private var theme
    @ObservedObject private var flow = SetupFlow.shared
    let module: Module
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let progress = module.setupProgress
        let onlyOptional = progress.requiredDone
        if progress.total > 0, !progress.allDone, !(onlyOptional && flow.isBannerHidden(module)) {
            HStack(spacing: 10) {
                Image(systemName: onlyOptional ? "checklist" : "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(onlyOptional ? theme.accent(module) : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Настройка: \(progress.done) из \(progress.total)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text(onlyOptional ? "Осталось необязательное" : "Без этого «\(module.title)» работает не полностью")
                        .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                if onlyOptional { DSButton("Не показывать", style: .plain, small: true) { flow.hideBanner(module) } }
                DSButton("Продолжить", icon: "arrow.right", style: onlyOptional ? .secondary : .primary, small: true) {
                    flow.show(module)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
            .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.7))
            .padding(.horizontal, DS.pagePadding).padding(.top, 10)
            .environment(\.dsTint, theme.accent(module))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if pageActive { tick += 1 }
            }
            .onPageActive { if $0 { tick += 1 } }
        } else {
            // Ни плашки, ни подписок: но обновиться при показе страницы всё равно нужно.
            Color.clear.frame(height: 0).onPageActive { if $0 { tick += 1 } }
        }
    }
}
