import SwiftUI

private struct ClassicMixerRow: View {
    let app: MixerApp
    @ObservedObject var controller: MixerController

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                if app.muted {
                    Text("без звука").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Slider(value: Binding(
                get: { app.volume },
                // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                set: { controller.setVolume(($0 * 100).rounded() / 100, for: app.id) }
            ), in: 0...1)
            .opacity(app.muted ? 0.4 : 1)

            Text("\(Int((app.volume * 100).rounded())) %")
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)

            Button {
                controller.setMuted(!app.muted, for: app.id)
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(app.muted ? Color.red : .secondary)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help(app.muted ? "Вернуть звук" : "Выключить звук")
        }
        .padding(.vertical, 2)
    }
}

/// Приложение не запущено, но для него задана громкость: можно только сбросить.
private struct ClassicPresetRow: View {
    let app: MixerApp
    @ObservedObject var controller: MixerController

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
            Text(app.name).lineLimit(1)
            Spacer()
            Text(app.muted ? "без звука" : "\(Int((app.volume * 100).rounded())) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Сбросить") { controller.reset(app.id) }
                .buttonStyle(.borderless)
        }
    }
}

struct ClassicMixerView: View {
    @ObservedObject private var controller = MixerController.shared
    @State private var showOthers = false

    var body: some View {
        Form {
            if controller.permissionProblem {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Нужно разрешение «Запись системного звука»", systemImage: "lock.shield")
                            .font(.headline)
                        Text("Без него громкость не меняется. Включи Utilitumus в «Конфиденциальность и безопасность → Запись экрана и системного звука» и перезапусти приложение.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Открыть настройки…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        if let error = controller.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Сейчас играют") {
                if controller.apps.isEmpty {
                    Text("Сейчас ничего не играет.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.apps) { app in
                    ClassicMixerRow(app: app, controller: controller)
                }
            }

            if !controller.idleApps.isEmpty {
                Section {
                    ForEach(controller.idleApps) { app in
                        ClassicMixerRow(app: app, controller: controller)
                    }
                } header: {
                    Text("Молчат сейчас")
                } footer: {
                    Text("Настрой заранее: громкость запомнится и применится, когда приложение начнёт звучать.")
                }
            }

            if !controller.otherApps.isEmpty {
                Section {
                    // Кликается вся строка, а не только стрелка.
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showOthers.toggle() }
                    } label: {
                        HStack {
                            Text("Остальные запущенные")
                            Text("\(controller.otherApps.count)").foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showOthers ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    if showOthers {
                        ForEach(controller.otherApps) { app in
                            ClassicMixerRow(app: app, controller: controller)
                        }
                    }
                } footer: {
                    Text("Звука от них обычно нет. Зазвучат — переедут наверх.")
                }
            }

            if !controller.presetApps.isEmpty {
                Section {
                    DisclosureGroup("Настроены заранее (\(controller.presetApps.count))") {
                        ForEach(controller.presetApps) { app in
                            ClassicPresetRow(app: app, controller: controller)
                        }
                    }
                }
            }

            Section {
                Text("Выше 100 % громкость не поднять. При выходе из Utilitumus всё возвращается как было.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Микшер")
        .navigationSubtitle(controller.apps.isEmpty ? "" : "Играют: \(controller.apps.count)")
    }
}
