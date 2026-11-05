import SwiftUI

/// Экран модуля «Клавиатура».
struct KeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared

    var body: some View {
        DSPage(module: .keyboard, subtitle: "Мгновенная смена раскладки по тапу Fn/🌐") {
            if controller.secureInputApp != nil { warnings }

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
                // Отключить действие можно в чек-листе настройки (плашка сверху).
                DSRow(icon: "globe", title: "Системное действие 🌐",
                      subtitle: controller.systemUsage == 0 ? "Отключено, второго переключения не будет"
                          : "macOS тоже переключит язык, и он сменится дважды. Отключается в настройке модуля") {
                    DSChip(FnSystemAction.title(for: controller.systemUsage),
                           color: controller.systemUsage == 0 ? .green : .orange,
                           icon: controller.systemUsage == 0 ? "checkmark" : "exclamationmark.triangle.fill")
                }
                DSRow(title: status.text) {
                    Image(systemName: status.icon).foregroundStyle(status.color)
                }
                DSRow(icon: "wrench.and.screwdriver.fill", title: "Если переключение не работает",
                      subtitle: controller.repairResult ?? "Сбросит системное действие Fn, пересоздаст прослушивание и сверит раскладку") {
                    DSButton("Починить", small: true) { controller.repair() }
                }
            }

            KeyboardLogSection(controller: controller)
        }
        .onPageActive { if $0 { controller.refreshAccess(); controller.refreshSystem() } }
    }

    /// Защищённый ввод: пока он включён, macOS не отдаёт нажатия. Остальные конфликты решает чек-лист настройки.
    private var warnings: some View {
        DSSection("Конфликты с системой") {
            if let app = controller.secureInputApp {
                DSRow(icon: "lock.fill", title: "Сейчас Fn не слышно",
                      subtitle: "Защищённый ввод в «\(app)»: пока он включён, macOS не отдаёт нажатия. Выйди из поля пароля или отключи Secure Keyboard Entry.",
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

/// Сворачиваемая строка «Журнал (N)»: последние записи и кнопка «Скопировать журнал».
private struct KeyboardLogSection: View {
    @ObservedObject var controller: KeyboardController
    @State private var expanded = false

    var body: some View {
        DSSection("Журнал") {
            DSRow(icon: "doc.text", title: "Журнал (\(controller.logCount))",
                  subtitle: "Пришли его, если переключение перестало работать") {
                HStack(spacing: 8) {
                    DSButton("Скопировать журнал", icon: "doc.on.doc", small: true) { controller.copyLog() }
                    DSButton(expanded ? "Скрыть" : "Показать", small: true) { expanded.toggle() }
                }
            }
            if expanded {
                ForEach(Array(controller.logTail.enumerated()), id: \.offset) { _, entry in
                    DSRow(title: "\(KeyboardLog.shortTime(entry.date))  \(entry.text)") { EmptyView() }
                }
            }
        }
    }
}
