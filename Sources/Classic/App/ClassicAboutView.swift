import SwiftUI

/// Страница «О проекте». Не `Module`: у неё нет состояния в настройках.
struct ClassicAboutView: View {
    /// Открыть модуль в основном окне (и показанный, и скрытый).
    let open: (Module) -> Void
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var updater = Updater.shared

    private static let groups: [(title: String, subtitle: String, modules: [Module])] = [
        ("Исправления MacBook", "То, что в macOS должно быть, но его нет", [.sound, .fans, .mixer, .mouse]),
        ("Утилиты с фишками", "Мелочи, которые экономят время каждый день", [.stash, .browser, .voice]),
        ("Для работы с ИИ", "Когда агенты съедают память", [.load]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(.headline)
                            Text(group.subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                            ForEach(group.modules) { module in
                                ClassicModuleCard(module: module, on: modules.isOn(module),
                                           hidden: modules.isHidden(module)) { open(module) }
                            }
                        }
                    }
                }
                footer
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("О проекте")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Utilitumus").font(.largeTitle.bold())
                    Text(updater.currentVersion)
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text("Тонкая настройка MacBook там, где macOS её не даёт. Одно лёгкое приложение вместо россыпи утилит.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        WhatsNew.shared.isShown = true
                    } label: {
                        Label("Что нового", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        updater.check()
                    } label: {
                        Label("Проверить обновления", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Link(destination: URL(string: "https://github.com/\(Updater.repo)")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.10), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        }
    }

    private var footer: some View {
        let on = Module.allCases.filter { modules.isOn($0) }.count
        return HStack(spacing: 6) {
            Text("Модулей: \(Module.allCases.count), включено: \(on).")
            Text("Открытый код — делай форк и предлагай свои модули.")
            Spacer()
            Button("Настроить модули") { modules.settingsShown = true }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Карточка модуля: значок, название, одна строка о нём и состояние. Клик — открыть.
private struct ClassicModuleCard: View {
    let module: Module
    let on: Bool
    let hidden: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ClassicModuleIconBadge(module: module, size: 36)
                    .saturation(on ? 1 : 0.3)
                    .opacity(on ? 1 : 0.7)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(module.title).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        status
                    }
                    Text(module.info.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovered ? 0.12 : 0.06)))
            .scaleEffect(hovered ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .roundedFocusRing(12)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovered = h } }
        .help(on ? "Открыть" : "Открыть — там его можно включить")
    }

    @ViewBuilder
    private var status: some View {
        let (text, color): (String, Color) = !on ? ("выключен", .secondary)
            : hidden ? ("в фоне", .orange) : ("включён", .green)
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}
