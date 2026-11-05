import SwiftUI

/// Экран модуля «Клавиатура».
struct ClassicKeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared

    var body: some View {
        Form {
            if controller.systemUsage != 0 {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Система тоже переключит язык по 🌐: сейчас «\(FnSystemAction.title(for: controller.systemUsage))»",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Отключить системное действие") { controller.disableSystemAction() }
                                .buttonStyle(.borderedProminent)
                            Button("Открыть настройки клавиатуры") { controller.openKeyboardSettings() }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if controller.dictationConflict {
                Section {
                    Label("Диктовка включается двойным нажатием 🌐 и будет срабатывать вместе с переключением. Поменяй сочетание в «Клавиатура → Диктовка».",
                          systemImage: "mic.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Когда менять язык") {
                    SegmentedControl(FnTrigger.allCases, selection: $controller.trigger) { $0.title }
                }
                LabeledContent("Какой язык следующий") {
                    SegmentedControl(LayoutMode.allCases, selection: $controller.mode) { $0.title }
                }
            } header: {
                Text("Как переключать")
            } footer: {
                Text("Тап — нажал и отпустил Fn, ничего не нажимая между. «При нажатии» быстрее, но сработает и при Fn+другая клавиша.")
            }

            Section("Состояние") {
                LabeledContent("Сейчас включена", value: controller.currentName)
                LabeledContent("Системное действие 🌐", value: FnSystemAction.title(for: controller.systemUsage))
                Label(status.text, systemImage: status.icon)
                    .foregroundStyle(status.color)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Клавиатура")
        .onAppear { controller.refreshAccess(); controller.refreshSystem() }
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
