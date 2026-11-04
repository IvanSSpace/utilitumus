import SwiftUI

/// Экран модуля «Мышь».
struct MouseView: View {
    @ObservedObject var controller = MouseController.shared

    var body: some View {
        Form {
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
                Text("«Как трекпад» — так, как сейчас настроено в macOS (Системные настройки → Трекпад → Естественная прокрутка). Трекпад Utilitumus не трогает. Мышь с колесом определяется по тому, что у её прокрутки нет фаз жеста, Magic Mouse — по данным HID.")
            }

            Section {
                Toggle("Плавная прокрутка", isOn: $controller.settings.smoothEnabled)
                LabeledContent("Скорость") {
                    HStack {
                        Slider(value: $controller.settings.speed, in: MouseSettings.speedRange, step: 0.1)
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
                Text("Щелчки колеса превращаются в плавную прокрутку с мягким стартом и доездом. Трекпад и Magic Mouse не затрагиваются. С зажатыми Cmd, Ctrl, Opt и Shift прокрутка остаётся обычной.")
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
