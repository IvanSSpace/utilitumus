import SwiftUI

/// Экран модуля: содержимое — или, пока модуль выключен, описание с кнопкой «Включить»,
/// а если включён, но не выдан обязательный доступ, — экран «Осталось дать доступ».
/// «Как это работает» и переключатель «Включён» модуля рисует шапка `DSPage`. Экран, ещё не переведённый
/// на `DSPage`, получает вместо неё компактную полоску с теми же кнопками.
/// Выключенный модуль ничего не делает и экран его не запускает.
struct ModuleScreen<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var modules = ModuleManager.shared
    @State private var hasPage = false
    /// Меняется, когда экран доступа решил перепроверить требования.
    @State private var recheck = 0

    var body: some View {
        let _ = recheck
        if !modules.isOn(module) {
            ModuleOffView(module: module) { modules.setOn(module, true) } more: { modules.infoModule = module }
        } else if !module.blockingRequirements.isEmpty {
            ModuleSetupView(module: module) { recheck += 1 }
        } else {
            VStack(spacing: 0) {
                if !hasPage { CompatBar(module: module) }
                content
            }
            .onPreferenceChange(DSPageKey.self) { hasPage = $0 }
        }
    }
}

/// Полоска для экрана без `DSPage`: название и кнопки, которые раньше были в заголовке окна.
private struct CompatBar: View {
    let module: Module

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 24)
            Text(module.title).font(.system(size: 15, weight: .semibold))
            Spacer()
            DSModuleControls(module: module)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// Модуль выключен: что он делает, что умеет, что понадобится, и кнопка «Включить».
struct ModuleOffView: View {
    let module: Module
    let enable: () -> Void
    let more: () -> Void
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let info = module.info
        let abilities = Array((info.sections.first?.points ?? []).prefix(3))
        let needs = module.requirements
        ModuleCentered(module: module, title: module.title, lead: info.lead) {
            VStack(spacing: 14) {
            if module == .mouse { DSChip("На доработке", color: .orange, icon: "hammer.fill") }
            HStack(alignment: .top, spacing: 16) {
                if !abilities.isEmpty {
                    column("Что умеет") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(abilities.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                        .foregroundStyle(theme.accent(module))
                                    Text(point).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
                column("Понадобится") {
                    if needs.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                            Text("Ничего: включил и работает").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(needs) { ModuleRequirementRow(requirement: $0, compact: true) }
                        }
                    }
                }
            }
            }
            .environment(\.dsTint, theme.accent(module))
        } actions: {
            DSButton("Включить", icon: "power", style: .primary, action: enable)
                .environment(\.dsTint, theme.accent(module))
                .controlSize(.large)
            DSButton("Подробнее", icon: "info.circle", action: more)
        }
    }

    private func column<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(DS.sectionTitle).tracking(0.8)
                .foregroundStyle(.white.opacity(0.42)).padding(.horizontal, 6)
            content().modifier(ModuleCard())
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Страница «Об инструменте».
struct ModuleInfoSheet: View {
    let module: Module
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = module.info
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ModuleIconBadge(module: module, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title).font(.title2.weight(.semibold))
                            Text(info.tagline).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text(info.lead)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(info.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(point).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
    }
}

extension View {
    /// Рамка фокуса клавиатуры (Tab) по скруглению кнопки. У кнопок со стилем `.plain`
    /// и своим фоном macOS рисует прямоугольник по краю, и углы торчат; задать ему форму
    /// через contentShape(.focusEffect) не выходит. Поэтому системную рамку выключаем
    /// и рисуем свою — того же цвета и толщины, но по скруглению.
    func roundedFocusRing(_ radius: CGFloat) -> some View {
        modifier(RoundedFocusRing(radius: radius))
    }
}

private struct RoundedFocusRing: ViewModifier {
    let radius: CGFloat
    @FocusState private var focused: Bool
    private let width: CGFloat = 3.5

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: radius + width, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: width)
                    .padding(-width)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}
