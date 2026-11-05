import SwiftUI

/// Экран модуля «Клавиатура».
struct KeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared

    var body: some View {
        DSPage(module: .keyboard, subtitle: "Мгновенная смена раскладки по тапу Fn/🌐") {
            if controller.systemUsage != 0 { systemWarning }
            if controller.dictationConflict { dictationWarning }

            DSSection("Как переключать") {
                DSRow(icon: "hand.tap.fill", title: "Когда менять язык",
                      subtitle: "«При нажатии» быстрее, но сработает и при Fn+другая клавиша") {
                    DSSegmented(FnTrigger.allCases, selection: $controller.trigger) { $0.title }
                }
                DSRow(icon: "arrow.left.arrow.right", title: "Какой язык следующий",
                      subtitle: "Порядок раскладок — как в системе") {
                    DSSegmented(LayoutMode.allCases, selection: $controller.mode) { $0.title }
                }
            }

            DSSection("Состояние") {
                DSRow(icon: "keyboard.fill", title: "Сейчас включена") {
                    DSChip(controller.currentName, color: .secondary)
                }
                DSRow(icon: "globe", title: "Системное действие 🌐",
                      subtitle: controller.systemUsage == 0 ? "Отключено, второго переключения не будет"
                                                            : "Включено в macOS, язык может переключиться второй раз") {
                    DSChip(FnSystemAction.title(for: controller.systemUsage),
                           color: controller.systemUsage == 0 ? .green : .orange,
                           icon: controller.systemUsage == 0 ? "checkmark" : "exclamationmark.triangle.fill")
                }
                DSRow(title: status.text) {
                    Image(systemName: status.icon).foregroundStyle(status.color)
                }
            }
        }
        .onPageActive { if $0 { controller.refreshAccess(); controller.refreshSystem() } }
    }

    private var systemWarning: some View {
        DSSection("Конфликт с системой", trailing: "Нужно отключить") {
            DSRow(icon: "exclamationmark.triangle.fill", title: "Система тоже переключит язык",
                  subtitle: "Нажатие 🌐 в macOS сейчас: «\(FnSystemAction.title(for: controller.systemUsage))». С ним язык поменяется дважды.",
                  iconTint: .orange) { EmptyView() }
            DSRow(title: "Что сделать") {
                HStack(spacing: 8) {
                    DSButton("Отключить системное действие", icon: "bolt.slash.fill", style: .primary, small: true) {
                        controller.disableSystemAction()
                    }
                    DSButton("Открыть настройки клавиатуры", icon: "gearshape", small: true) {
                        controller.openKeyboardSettings()
                    }
                }
            }
        }
    }

    private var dictationWarning: some View {
        DSSection("Диктовка") {
            DSRow(icon: "mic.fill", title: "Диктовка включается двойным нажатием 🌐",
                  subtitle: "Она будет срабатывать вместе с переключением. Поменяй сочетание в «Клавиатура → Диктовка».",
                  iconTint: .orange) { EmptyView() }
        }
    }

    private var status: (text: String, icon: String, color: Color) {
        if !controller.inputAccess {
            return ("Нет доступа «Мониторинг ввода», клавиша не слышна", "exclamationmark.triangle", .orange)
        }
        return controller.tapActive
            ? ("Слушаю клавишу Fn, тап переключает язык сразу", "checkmark.circle.fill", .green)
            : ("Запускаю прослушивание…", "hourglass", .secondary)
    }
}
