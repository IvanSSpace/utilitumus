import SwiftUI

/// Страница «О проекте». Не `Module`: она не включается и не выключается в настройках.
struct AboutView: View {
    /// Открыть модуль в основном окне (вызывается только для включённых).
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Utilitumus").font(.largeTitle.bold())
                    Text("Тонкая настройка MacBook там, где macOS её не даёт.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Зачем") {
                Text("У MacBook есть мелкие, но раздражающие проблемы, а кому-то нужны настройки, которых в системе просто нет. Хочется, чтобы перед игрой вентиляторы сразу работали на максимум и ноутбук не перегревался. Чтобы Bluetooth-наушники не перехватывали микрофон и не портили звук. Чтобы перед работой или игрой закрывалось лишнее, а при нехватке памяти не забивался своп. Обычно на каждый такой случай ставят отдельную программу. Utilitumus собирает эти возможности в одном приложении и делит их на блоки.")
            }

            Section("Исправления MacBook") {
                Text("То, что в macOS должно быть, но его нет.")
                    .foregroundStyle(.secondary)
                moduleRow(.sound, "основной микрофон и выход; случайный провод или Bluetooth-наушники их не перехватят.")
                moduleRow(.fans, "полная мощность одной кнопкой, свои режимы и кривые, защита от перегрева.")
                moduleRow(.mixer, "громкость каждого приложения отдельно.")
                moduleRow(.mouse, "прокрутка мыши отдельно от трекпада: своё направление и плавное движение вместо рывков колеса.")
            }

            Section("Утилиты с фишками") {
                moduleRow(.stash, "одной кнопкой закрыть лишнее перед игрой или работой и потом вернуть всё на свои места; видно, какие программы тяжёлые.")
            }

            Section("Для работы с ИИ") {
                moduleRow(.load, "сколько памяти и свопа занимают сессии Claude Code, модели и программы; что можно освободить, чтобы места всегда хватало.")
            }

            Section("Проект") {
                HStack(spacing: 4) {
                    Text("Открытый код:")
                    Link("github.com/IvanSSpace/utilitumus",
                         destination: URL(string: "https://github.com/IvanSSpace/utilitumus")!)
                }
                HStack(spacing: 4) {
                    Text("Ненужные модули можно выключить в")
                    SettingsLink {
                        Text("Настройках (Cmd+,)")
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("О проекте")
    }

    @ViewBuilder
    private func moduleRow(_ module: Module, _ text: String) -> some View {
        let on = modules.isEnabled(module)
        Button {
            open(module)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: module.icon)
                    .frame(width: 22)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(module.title).fontWeight(.semibold)) — \(text)")
                    if !on {
                        Text("выключен в Настройках")
                            .font(.caption)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Выключенный модуль открыть нельзя: его нет в боковой панели.
        .disabled(!on)
    }
}
