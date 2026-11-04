import SwiftUI

/// Экран модуля: содержимое — или, пока модуль выключен, описание с кнопкой «Включить».
/// (i) и переключатель — в строке заголовка окна, отдельной полосы над экраном нет.
/// Выключенный модуль ничего не делает и экран его не запускает.
struct ModuleScreen<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var modules = ModuleManager.shared
    @State private var showInfo = false

    var body: some View {
        let on = modules.isOn(module)
        Group {
            if on {
                content
            } else {
                ModuleOffView(module: module) { modules.setOn(module, true) } more: { showInfo = true }
                    .navigationTitle(module.title)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showInfo = true
                } label: {
                    Label("Об инструменте", systemImage: "info.circle")
                }
                .help("Об инструменте")
                Toggle("Модуль включён", isOn: Binding(get: { on }, set: { modules.setOn(module, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(on ? "Выключить: модуль остановится полностью" : "Включить модуль")
            }
        }
        .sheet(isPresented: $showInfo) { ModuleInfoSheet(module: module) }
    }
}

/// Модуль выключен: что он делает и кнопка «Включить».
struct ModuleOffView: View {
    let module: Module
    let enable: () -> Void
    let more: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ModuleIconBadge(module: module, size: 56)
            Text(module.title).font(.title2.weight(.semibold))
            Text(module.info.lead)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                // Без fixedSize(vertical:): при узкой ширине на одном из проходов раскладки
                // NavigationSplitView текст вытягивался в тысячи точек и раздувал всё окно.
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Включить", action: enable)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Подробнее", action: more)
                    .controlSize(.large)
            }
            .padding(.top, 4)
            Text("Пока модуль выключен, он ничего не делает.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
