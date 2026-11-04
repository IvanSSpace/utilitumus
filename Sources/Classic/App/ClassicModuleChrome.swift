import SwiftUI

/// Экран модуля: содержимое — или, пока модуль выключен, описание с кнопкой «Включить».
/// (i) и переключатель — в строке заголовка окна (`ClassicModuleToolbar` в ClassicMainView), отдельной полосы нет.
/// Выключенный модуль ничего не делает и экран его не запускает.
struct ClassicModuleScreen<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        if modules.isOn(module) {
            content
        } else {
            ClassicModuleOffView(module: module) { modules.setOn(module, true) } more: { modules.infoModule = module }
                .navigationTitle(module.title)
        }
    }
}

/// (i) и переключатель модуля в строке заголовка. Висят на всём окне, а не на экране модуля:
/// иначе при каждом переключении вкладки macOS пересобирает панель инструментов (+30–40 мс).
struct ClassicModuleToolbar: ToolbarContent {
    let module: Module
    @ObservedObject var modules: ModuleManager

    var body: some ToolbarContent {
        let on = modules.isOn(module)
        // Подписанная кнопка, а не голый значок (i): так видно, что на неё можно нажать и что там.
        ToolbarItem(placement: .primaryAction) {
            Button {
                modules.infoModule = module
            } label: {
                Label("Как это работает", systemImage: "info.circle")
                    .labelStyle(.titleAndIcon)
                    // Системная капсула даёт тексту справа меньше воздуха, чем значку слева.
                    .padding(.trailing, 3)
            }
            .help("Что умеет модуль и как им пользоваться")
        }
        // Отдельной капсулой: переключатель не должен сливаться с кнопкой справки.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            // Подпись отдельным Text: у Toggle в панели инструментов macOS прячет label.
            HStack(spacing: 8) {
                Text(on ? "Включён" : "Выключен")
                    .foregroundStyle(on ? .primary : .secondary)
                Toggle("Модуль включён", isOn: Binding(get: { on }, set: { modules.setOn(module, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            // Поровну слева и справа: у капсулы свой внутренний отступ слева больше, чем справа.
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .frame(height: 28)
            .help(on ? "Выключить: модуль остановится полностью" : "Включить модуль")
        }
        // Кнопки самого модуля («Всё авто», «Обновить») — своей капсулой, не слипаются с переключателем.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}

/// Модуль выключен: что он делает и кнопка «Включить».
struct ClassicModuleOffView: View {
    let module: Module
    let enable: () -> Void
    let more: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ClassicModuleIconBadge(module: module, size: 56)
            Text(module.title).font(.title2.weight(.semibold))
            if module == .mouse {
                Label("На доработке", systemImage: "hammer.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: Capsule())
            }
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
