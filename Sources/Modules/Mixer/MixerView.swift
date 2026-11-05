import SwiftUI

/// Разделитель между строками карточки — как в `DSRow`, но строка ниже (38 вместо 50 pt),
/// чтобы микшер целиком помещался в стандартное окно.
private struct RowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(minHeight: 38)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 46)
            }
    }
}

private struct AppIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().frame(width: 26, height: 26)
    }
}

/// Строка получает значения и замыкания, а не контроллер: иначе каждая публикация
/// контроллера перерисовывала бы все строки. `Equatable` по `app` пропускает
/// пересчёт, когда у строки ничего не поменялось.
private struct MixerRow: View, Equatable {
    let app: MixerApp
    let onVolume: (Double) -> Void
    let onCommit: () -> Void
    let onToggleMute: () -> Void
    /// Строка в узкой колонке: имя короче, чтобы остался ход у ползунка.
    var narrow = false
    @Environment(\.dsTint) private var tint
    /// Значение под пальцем: слайдер двигается сразу, а список публикуется позже.
    @State private var dragging: Double?

    static func == (a: MixerRow, b: MixerRow) -> Bool { a.app == b.app && a.narrow == b.narrow }

    private var shownVolume: Double { dragging ?? app.volume }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                if app.muted {
                    Text("без звука").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: narrow ? 108 : 150, alignment: .leading)

            Slider(value: Binding(
                get: { shownVolume },
                // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                set: {
                    let value = ($0 * 100).rounded() / 100
                    dragging = value
                    onVolume(value)
                }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing { onCommit(); dragging = nil }
            })
            .tint(tint)
            .controlSize(.small)
            .opacity(app.muted ? 0.4 : 1)

            Text("\(Int((shownVolume * 100).rounded())) %")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, alignment: .trailing)

            Button {
                onToggleMute()
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(app.muted ? Color.red : .white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(app.muted ? "Вернуть звук" : "Выключить звук")
        }
        .modifier(RowDivider())
        .onChange(of: app.volume) { dragging = nil }
    }
}

/// Приложение не запущено, но для него задана громкость: можно только сбросить.
private struct PresetRow: View, Equatable {
    let app: MixerApp
    let onReset: () -> Void

    static func == (a: PresetRow, b: PresetRow) -> Bool { a.app == b.app }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
            Spacer(minLength: 6)
            Text(app.muted ? "без звука" : "\(Int((app.volume * 100).rounded())) %")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            DSButton("Сбросить", small: true) { onReset() }
        }
        .modifier(RowDivider())
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
    }
}

/// Сворачивающая строка «Остальных»: компактная, подсказка вместо пояснения.
private struct OthersToggle: View {
    let expanded: Bool
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "square.stack").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint))
            Text(expanded ? "Скрыть" : "Показать").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 6)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .modifier(RowDivider())
        .contentShape(Rectangle())
    }
}

struct MixerView: View {
    @ObservedObject private var controller = MixerController.shared
    @State private var showOthers = false

    private func row(_ app: MixerApp, narrow: Bool = false) -> some View {
        let id = app.id
        return MixerRow(
            app: app,
            onVolume: { controller.setVolume($0, for: id) },
            onCommit: { controller.commitVolumes() },
            onToggleMute: { controller.setMuted(!controller.isMuted(id), for: id) },
            narrow: narrow
        ).equatable()
    }

    private func idleSection(narrow: Bool) -> some View {
        DSSection("Молчат сейчас", trailing: "\(controller.idleApps.count)") {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(controller.idleApps) { app in row(app, narrow: narrow) }
            }
        }
        .help("Настрой заранее: громкость запомнится и применится, когда приложение начнёт звучать")
    }

    private func presetSection() -> some View {
        DSSection("Настроены заранее", trailing: "\(controller.presetApps.count)") {
            ForEach(controller.presetApps) { app in
                let id = app.id
                PresetRow(app: app, onReset: { controller.reset(id) }).equatable()
            }
        }
    }

    private func othersSection(narrow: Bool) -> some View {
        DSSection("Остальные запущенные", trailing: "\(controller.otherApps.count)") {
            // Кликается вся строка, а не только стрелка.
            Button {
                showOthers.toggle()
            } label: {
                OthersToggle(expanded: showOthers)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Звука от них обычно нет. Зазвучат — переедут наверх")
            if showOthers {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.otherApps) { app in row(app, narrow: narrow) }
                }
            }
        }
    }

    var body: some View {
        let left = !controller.idleApps.isEmpty || !controller.presetApps.isEmpty
        let right = !controller.otherApps.isEmpty
        // Две колонки, когда есть что поставить рядом: на стандартном окне это экономит высоту.
        let narrow = left && right
        DSPage(
            module: .mixer,
            subtitle: controller.apps.isEmpty ? "Сейчас ничего не играет" : "Играют: \(controller.apps.count)"
        ) {
            if controller.permissionProblem {
                DSSection("Нужно разрешение") {
                    DSRow(icon: "lock.shield", title: "Запись системного звука",
                          subtitle: "Без неё громкость не меняется. Включи Utilitumus в «Конфиденциальность и безопасность → Запись экрана и системного звука» и перезапусти приложение.") {
                        DSButton("Открыть настройки…", small: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if let error = controller.lastError {
                        DSRow(icon: "exclamationmark.triangle.fill", title: error)
                    }
                }
            }

            // Блоки ближе друг к другу, чем в остальных модулях: список здесь главное.
            VStack(alignment: .leading, spacing: 14) {
                DSSection("Сейчас играют", trailing: controller.apps.isEmpty ? nil : "\(controller.apps.count)") {
                    if controller.apps.isEmpty {
                        Text("Сейчас ничего не играет").font(DS.rowTitle).foregroundStyle(.white.opacity(0.6))
                            .modifier(RowDivider())
                    }
                    ForEach(controller.apps) { app in row(app) }
                }

                HStack(alignment: .top, spacing: 14) {
                    if left {
                        VStack(alignment: .leading, spacing: 14) {
                            if !controller.idleApps.isEmpty { idleSection(narrow: narrow) }
                            if !controller.presetApps.isEmpty { presetSection() }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    if right {
                        othersSection(narrow: narrow).frame(maxWidth: .infinity, alignment: .top)
                    }
                }

                Note("Выше 100 % громкость не поднять. При выходе из Utilitumus всё возвращается как было.")
            }
        }
        .onPageActive { controller.setScreenVisible($0) }
    }
}
