import SwiftUI

/// Страница «О проекте». Не `Module`: у неё нет состояния в настройках.
struct AboutView: View {
    /// Открыть модуль в основном окне (для показанных и скрытых; выключенные не открываются).
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
                Text("Вентиляторы на максимум перед игрой, наушники без захвата микрофона, лишнее закрыто перед работой. Всё это в одном приложении, а не в россыпи программ.")
            }

            Section("Исправления MacBook") {
                Text("То, что в macOS должно быть, но его нет.")
                    .foregroundStyle(.secondary)
                moduleRow(.sound, "основные микрофон и выход, которые не перехватят провод или Bluetooth.")
                moduleRow(.fans, "полная мощность одной кнопкой, свои режимы и кривые, защита от перегрева.")
                moduleRow(.mixer, "громкость каждого приложения отдельно.")
                moduleRow(.mouse, "прокрутка мыши отдельно от трекпада: своё направление и плавность.")
            }

            Section("Утилиты с фишками") {
                moduleRow(.stash, "закрыть лишнее одной кнопкой и вернуть всё на места.")
                moduleRow(.browser, "клик по ссылке открывает у курсора список браузеров; для частых случаев есть правила.")
            }

            Section("Для работы с ИИ") {
                moduleRow(.load, "сколько памяти и свопа занимают сессии Claude Code, модели и программы.")
            }

            Section("Проект") {
                HStack(spacing: 4) {
                    Text("Открытый код:")
                    Link("github.com/IvanSSpace/utilitumus",
                         destination: URL(string: "https://github.com/IvanSSpace/utilitumus")!)
                }
                HStack(spacing: 4) {
                    Text("Порядок, скрытие и выключение модулей — в")
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
        let on = modules.isOn(module)
        let hidden = modules.isHidden(module)
        Button {
            open(module)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ModuleIconBadge(module: module, size: 22)
                    .opacity(on ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(module.title).fontWeight(.semibold)) — \(text)")
                    if !on {
                        Text("выключен — открой, чтобы включить")
                            .font(.caption)
                    } else if hidden {
                        Text("скрыт из панели — работает в фоне")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
