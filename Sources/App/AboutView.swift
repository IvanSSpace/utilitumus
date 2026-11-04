import SwiftUI

/// Страница «О проекте». Не `Module`: у неё нет состояния в настройках.
struct AboutView: View {
    /// Открыть модуль в основном окне (и показанный, и скрытый).
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var updater = Updater.shared

    @Environment(\.dsTheme) private var theme

    var body: some View {
        DSPlainPage(icon: "info.circle", title: "О проекте",
                    subtitle: "Тонкая настройка MacBook там, где macOS её не даёт. Одно лёгкое приложение вместо россыпи утилит.") {
            hero
            ForEach(ModuleCategory.all) { group in
                DSSection(group.title, trailing: group.subtitle, mark: theme.categoryColor(group)) {
                    ForEach(group.modules) { module in
                        Button { open(module) } label: {
                            DSRow(icon: module.icon, title: module.title, subtitle: module.info.tagline,
                                  iconTint: theme.tone(module)) {
                                status(module)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(modules.isOn(module) ? "Открыть" : "Открыть — там его можно включить")
                    }
                }
            }
            footer
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Utilitumus").font(.system(size: 17, weight: .semibold))
                    DSChip("Версия \(updater.currentVersion)", color: .white.opacity(0.7))
                }
                HStack(spacing: 8) {
                    DSButton("Что нового", icon: "sparkles", style: .primary, small: true) {
                        WhatsNew.shared.isShown = true
                    }
                    DSButton("Проверить обновления", icon: "arrow.triangle.2.circlepath", small: true) {
                        updater.check()
                    }
                    DSButton("GitHub", icon: "chevron.left.forwardslash.chevron.right", small: true) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func status(_ module: Module) -> some View {
        if !modules.isOn(module) {
            DSChip("выключен", color: .gray)
        } else if modules.isHidden(module) {
            DSChip("в фоне", color: .orange)
        } else {
            DSChip("включён", color: .green)
        }
    }

    private var footer: some View {
        let on = Module.allCases.filter { modules.isOn($0) }.count
        return HStack(spacing: 6) {
            Text("Модулей: \(Module.allCases.count), включено: \(on).")
            Text("Открытый код — делай форк и предлагай свои модули.")
            Spacer()
            DSButton("Настроить модули", style: .plain, small: true) { modules.settingsShown = true }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.45))
    }
}
