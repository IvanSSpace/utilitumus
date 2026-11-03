import SwiftUI

private struct MixerRow: View {
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
                set: { controller.setVolume($0, for: app.id) }
            ), in: 0...1, step: 0.01)
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

struct MixerView: View {
    @ObservedObject private var controller = MixerController.shared

    var body: some View {
        Form {
            if controller.permissionProblem {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Нужно разрешение «Запись системного звука»", systemImage: "lock.shield")
                            .font(.headline)
                        Text("Без него macOS не даёт перехватить звук приложения, и громкость не меняется. Открой «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука», включи Utilitumus в разделе «Только запись системного звука» и перезапусти Utilitumus.")
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
                    Text("Ничего не играет. Приложение появится здесь, как только начнёт воспроизводить звук.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.apps) { app in
                    MixerRow(app: app, controller: controller)
                }
            }

            Section {
                Text("Пока у приложения 100 % и звук включён, Utilitumus его не трогает. Громкость выше 100 % не поддерживается. Звук идёт на устройство вывода по умолчанию. При выходе из Utilitumus всё возвращается как было.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Микшер")
        .navigationSubtitle(controller.apps.isEmpty ? "" : "Играют: \(controller.apps.count)")
    }
}
