import SwiftUI

/// Разделитель между строками карточки — как в `DSRow`.
private struct RowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 50)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 56)
            }
    }
}

private struct AppIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().frame(width: 30, height: 30)
    }
}

private struct MixerRow: View {
    let app: MixerApp
    @ObservedObject var controller: MixerController
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(image: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                if app.muted {
                    Text("без звука").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 150, alignment: .leading)

            Slider(value: Binding(
                get: { app.volume },
                // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                set: { controller.setVolume(($0 * 100).rounded() / 100, for: app.id) }
            ), in: 0...1)
            .tint(tint)
            .controlSize(.small)
            .opacity(app.muted ? 0.4 : 1)

            Text("\(Int((app.volume * 100).rounded())) %")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 46, alignment: .trailing)

            Button {
                controller.setMuted(!app.muted, for: app.id)
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(app.muted ? Color.red : .white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(app.muted ? "Вернуть звук" : "Выключить звук")
        }
        .modifier(RowDivider())
    }
}

/// Приложение не запущено, но для него задана громкость: можно только сбросить.
private struct PresetRow: View {
    let app: MixerApp
    @ObservedObject var controller: MixerController

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(image: app.icon)
            Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
            Spacer(minLength: 10)
            Text(app.muted ? "без звука" : "\(Int((app.volume * 100).rounded())) %")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            DSButton("Сбросить", small: true) { controller.reset(app.id) }
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

struct MixerView: View {
    @ObservedObject private var controller = MixerController.shared
    @State private var showOthers = false

    var body: some View {
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

            DSSection("Сейчас играют", trailing: controller.apps.isEmpty ? nil : "\(controller.apps.count)") {
                if controller.apps.isEmpty {
                    DSRow(title: "Сейчас ничего не играет")
                }
                ForEach(controller.apps) { app in
                    MixerRow(app: app, controller: controller)
                }
            }

            if !controller.idleApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DSSection("Молчат сейчас", trailing: "\(controller.idleApps.count)") {
                        ForEach(controller.idleApps) { app in
                            MixerRow(app: app, controller: controller)
                        }
                    }
                    Note("Настрой заранее: громкость запомнится и применится, когда приложение начнёт звучать.")
                }
            }

            if !controller.otherApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DSSection("Остальные запущенные", trailing: "\(controller.otherApps.count)") {
                        // Кликается вся строка, а не только стрелка.
                        Button {
                            showOthers.toggle()
                        } label: {
                            DSRow(icon: "square.stack", title: showOthers ? "Скрыть" : "Показать",
                                  subtitle: "Звука от них обычно нет. Зазвучат — переедут наверх.") {
                                Image(systemName: showOthers ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        if showOthers {
                            ForEach(controller.otherApps) { app in
                                MixerRow(app: app, controller: controller)
                            }
                        }
                    }
                }
            }

            if !controller.presetApps.isEmpty {
                DSSection("Настроены заранее", trailing: "\(controller.presetApps.count)") {
                    ForEach(controller.presetApps) { app in
                        PresetRow(app: app, controller: controller)
                    }
                }
            }

            Note("Выше 100 % громкость не поднять. При выходе из Utilitumus всё возвращается как было.")
        }
    }
}
