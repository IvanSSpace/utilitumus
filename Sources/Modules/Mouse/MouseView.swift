import SwiftUI

/// Экран модуля «Мышь».
struct MouseView: View {
    @ObservedObject var controller = MouseController.shared

    var body: some View {
        Form {
            // Модуль работает, но интерфейс и возможности ещё будут переделаны.
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("На доработке").fontWeight(.semibold)
                        Text("Работает, но скоро станет удобнее.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.orange)
                }
            }

            if !controller.axTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Чтобы менять прокрутку мыши, дай Utilitumus «Универсальный доступ»",
                              systemImage: "lock.shield")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Дать доступ…") { controller.requestAccess() }
                            .buttonStyle(.borderedProminent)
                        Text("Без доступа прокрутка остаётся такой, как настроена в macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                directionPicker("Мышь", $controller.settings.mouseDirection)
                directionPicker("Magic Mouse", $controller.settings.magicMouseDirection)
            } header: {
                Text("Направление прокрутки")
            } footer: {
                Text("«Как трекпад» берёт направление из настроек macOS.")
            }

            Section {
                Toggle("Плавная прокрутка", isOn: $controller.settings.smoothEnabled)
                LabeledContent("Скорость") {
                    HStack {
                        Slider(value: Binding(get: { controller.settings.speed },
                                              set: { controller.settings.speed = ($0 * 10).rounded() / 10 }),
                               in: MouseSettings.speedRange)
                        Text(String(format: "%.1f×", controller.settings.speed))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!controller.settings.smoothEnabled)
                LabeledContent("Плавность") {
                    HStack {
                        Slider(value: $controller.settings.smoothness, in: 0...1)
                        Text("\(Int((controller.settings.smoothness * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!controller.settings.smoothEnabled)
            } header: {
                Text("Плавность мыши")
            } footer: {
                Text("Колесо крутит плавно, а не рывками. С Cmd, Ctrl, Opt или Shift — как обычно.")
            }

            Section("Состояние") {
                Label(status.text, systemImage: status.icon)
                    .foregroundStyle(status.color)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Мышь")
        .onAppear { controller.refreshAccess() }
    }

    private func directionPicker(_ title: String, _ selection: Binding<ScrollDirection>) -> some View {
        LabeledContent(title) {
            SegmentedControl(ScrollDirection.allCases, selection: selection) { $0.title }
        }
    }

    private var status: (text: String, icon: String, color: Color) {
        if !controller.settings.needsTap {
            return ("Всё как в системе, перехват прокрутки не нужен", "checkmark.circle", .secondary)
        }
        if !controller.axTrusted {
            return ("Нет доступа «Универсальный доступ», настройки не действуют", "exclamationmark.triangle", .orange)
        }
        return controller.tapActive
            ? ("Перехват прокрутки работает", "checkmark.circle.fill", .green)
            : ("Запускаю перехват…", "hourglass", .secondary)
    }
}
