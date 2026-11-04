import SwiftUI

/// Экран модуля: шапка (что это, (i), переключатель) и содержимое — или, пока модуль выключен,
/// описание с кнопкой «Включить». Выключенный модуль ничего не делает и экран его не запускает.
struct ModuleScreen<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var modules = ModuleManager.shared
    @State private var showInfo = false

    var body: some View {
        let on = modules.isOn(module)
        VStack(spacing: 0) {
            ModuleHeader(module: module, isOn: Binding(get: { on }, set: { modules.setOn(module, $0) }),
                         showInfo: $showInfo)
            Divider()
            if on {
                content
            } else {
                ModuleOffView(module: module) { modules.setOn(module, true) } more: { showInfo = true }
                    .navigationTitle(module.title)
            }
        }
        .sheet(isPresented: $showInfo) { ModuleInfoSheet(module: module) }
    }
}

/// Полоса над экраном модуля: значок, строка о модуле, (i) и переключатель.
struct ModuleHeader: View {
    let module: Module
    @Binding var isOn: Bool
    @Binding var showInfo: Bool

    var body: some View {
        HStack(spacing: 12) {
            ModuleIconBadge(module: module, size: 28)
                .opacity(isOn ? 1 : 0.5)
            Text(module.info.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            // Без квадратной обводки фокуса: окно открывается с фокусом на первой кнопке.
            .focusable(false)
            .help("Об инструменте")
            Spacer(minLength: 12)
            Toggle(isOn ? "Включён" : "Выключен", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .focusable(false)
                .help(isOn ? "Выключить: модуль остановится полностью" : "Включить модуль")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
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
                        Text(module.title).font(.title2.weight(.semibold))
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
