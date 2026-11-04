import SwiftUI

/// Экран модуля: содержимое — или, пока модуль выключен, описание с кнопкой «Включить».
/// «Как это работает» и переключатель «Включён» рисует шапка `DSPage`. Экран, ещё не переведённый
/// на `DSPage`, получает вместо неё компактную полоску с теми же кнопками.
/// Выключенный модуль ничего не делает и экран его не запускает.
struct ModuleScreen<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var modules = ModuleManager.shared
    @State private var hasPage = false

    var body: some View {
        if modules.isOn(module) {
            VStack(spacing: 0) {
                if !hasPage { CompatBar(module: module) }
                content
            }
            .onPreferenceChange(DSPageKey.self) { hasPage = $0 }
        } else {
            ModuleOffView(module: module) { modules.setOn(module, true) } more: { modules.infoModule = module }
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

/// Модуль выключен: что он делает и кнопка «Включить».
struct ModuleOffView: View {
    let module: Module
    let enable: () -> Void
    let more: () -> Void

    var body: some View {
        DSPage(module: module, subtitle: module.info.tagline,
               primary: DSAction("Включить", icon: "power", action: enable), controls: false) {
            DSSection("О модуле", trailing: module == .mouse ? nil : "выключен") {
                VStack(alignment: .leading, spacing: 12) {
                    if module == .mouse { DSChip("На доработке", color: .orange, icon: "hammer.fill") }
                    Text(module.info.lead)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        DSButton("Подробнее", icon: "info.circle", action: more)
                        Text("Пока модуль выключен, он ничего не делает.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
