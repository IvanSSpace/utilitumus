import SwiftUI

/// Экран модуля «Клавиатура».
struct KeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared

    var body: some View {
        DSPage(module: .keyboard, subtitle: "Мгновенная смена раскладки по тапу Fn/🌐") {
            if controller.systemUsage != 0 || controller.dictationConflict { warnings }

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
                // Пока есть предупреждение, оно само говорит про системное действие.
                if controller.systemUsage == 0 {
                    DSRow(icon: "globe", title: "Системное действие 🌐",
                          subtitle: "Отключено, второго переключения не будет") {
                        DSChip(FnSystemAction.title(for: controller.systemUsage), color: .green, icon: "checkmark")
                    }
                }
                DSRow(title: status.text) {
                    Image(systemName: status.icon).foregroundStyle(status.color)
                }
            }
        }
        .onPageActive { if $0 { controller.refreshAccess(); controller.refreshSystem() } }
    }

    private var warnings: some View {
        DSSection("Конфликты с системой", trailing: "Лучше отключить") {
            if controller.systemUsage != 0 {
                DSRow(icon: "exclamationmark.triangle.fill", title: "Система тоже переключит язык",
                      subtitle: "Нажатие 🌐 в macOS сейчас: «\(FnSystemAction.title(for: controller.systemUsage))». С ним язык поменяется дважды.",
                      iconTint: .orange) {
                    VStack(alignment: .trailing, spacing: 6) {
                        DSButton("Отключить системное действие", icon: "bolt.slash.fill", style: .primary, small: true) {
                            controller.disableSystemAction()
                        }
                        DSButton("Открыть настройки клавиатуры", icon: "gearshape", small: true) {
                            controller.openKeyboardSettings()
                        }
                    }
                }
            }
            if controller.dictationConflict {
                DSRow(icon: "mic.fill", title: "Диктовка включается двойным нажатием 🌐",
                      subtitle: "Она будет срабатывать вместе с переключением. Поменяй сочетание в «Клавиатура → Диктовка».",
                      iconTint: .orange) { EmptyView() }
            }
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
