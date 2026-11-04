import SwiftUI

/// Экран модуля «Мышь».
struct MouseView: View {
    @ObservedObject var controller = MouseController.shared

    var body: some View {
        DSPage(module: .mouse, subtitle: "Направление и плавность прокрутки колеса") {
            // Модуль работает, но интерфейс и возможности ещё будут переделаны.
            HStack(spacing: 10) {
                DSChip("На доработке", color: .orange, icon: "hammer.fill")
                Text("Работает, но скоро станет удобнее.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 6)

            DSSection("Направление прокрутки", trailing: "«Как трекпад» — из настроек macOS") {
                directionRow("Мышь", icon: "computermouse.fill", $controller.settings.mouseDirection)
                directionRow("Magic Mouse", icon: "magicmouse.fill", $controller.settings.magicMouseDirection)
            }

            DSSection("Плавность мыши", trailing: "С ⌘, ⌃, ⌥ или ⇧ — как обычно") {
                DSRow(icon: "scroll.fill", title: "Плавная прокрутка",
                      subtitle: "Колесо крутит плавно, а не рывками") {
                    DSToggle("Плавная прокрутка", isOn: $controller.settings.smoothEnabled)
                }
                sliderRow("Скорость", icon: "speedometer",
                          value: Binding(get: { controller.settings.speed },
                                         set: { controller.settings.speed = ($0 * 10).rounded() / 10 }),
                          range: MouseSettings.speedRange,
                          text: String(format: "%.1f×", controller.settings.speed))
                sliderRow("Плавность", icon: "waveform.path",
                          value: $controller.settings.smoothness, range: 0...1,
                          text: "\(Int((controller.settings.smoothness * 100).rounded())) %")
            }

            DSSection("Состояние") {
                DSRow(icon: "lock.shield.fill", title: "Универсальный доступ",
                      subtitle: controller.axTrusted ? nil : "Без доступа прокрутка остаётся такой, как в macOS") {
                    if controller.axTrusted {
                        DSChip("Разрешён", color: .green, icon: "checkmark")
                    } else {
                        DSButton("Дать доступ…", style: .primary, small: true) { controller.requestAccess() }
                    }
                }
                DSRow(title: status.text) {
                    Image(systemName: status.icon).foregroundStyle(status.color)
                }
            }
        }
        .onAppear { controller.refreshAccess() }
    }

    private func directionRow(_ title: String, icon: String, _ selection: Binding<ScrollDirection>) -> some View {
        DSRow(icon: icon, title: title) {
            DSSegmented(ScrollDirection.allCases, selection: selection) { $0.title }
        }
    }

    private func sliderRow(_ title: String, icon: String, value: Binding<Double>,
                           range: ClosedRange<Double>, text: String) -> some View {
        let enabled = controller.settings.smoothEnabled
        return DSRow(icon: icon, title: title) {
            TintedSlider(value: value, range: range)
            Text(text)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
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

/// Слайдер с акцентом модуля. Акцент задаёт `DSPage`, поэтому читать его надо ниже страницы.
private struct TintedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.dsTint) private var tint

    var body: some View {
        Slider(value: $value, in: range).tint(tint).frame(width: 200)
    }
}
