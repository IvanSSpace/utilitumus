import SwiftUI

/// Экран модуля «Клавиатура».
struct ClassicKeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared

    var body: some View {
        Form {
            if let app = controller.secureInputApp {
                Section {
                    Label("Сейчас Fn не слышно: защищённый ввод в «\(app)»",
                          systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Диктовка включается двойным нажатием 🌐: иначе двойной тап Fn её вызовет. Верну, когда выключишь модуль.",
                              systemImage: "mic.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Убрать диктовку с двойного Fn") { controller.disableDictationDoubleFn() }
                                .buttonStyle(.borderedProminent)
                            Button("Открыть настройки диктовки") { controller.openKeyboardSettings() }
                        }
                    }
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

            Section {
                DisclosureGroup("Журнал (\(controller.logCount))") {
                    ForEach(Array(controller.logTail.enumerated()), id: \.offset) { _, entry in
                        Text("\(KeyboardLog.shortTime(entry.date))  \(entry.text)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Скопировать журнал") { controller.copyLog() }
                }
            }

            Section("Состояние") {
                LabeledContent("Сейчас включена", value: controller.currentName)
                LabeledContent("Системное действие 🌐", value: FnSystemAction.title(for: controller.systemUsage))
                Label(status.text, systemImage: status.icon)
                    .foregroundStyle(status.color)
                LabeledContent("Если переключение не работает") {
                    Button("Починить") { controller.repair() }
                }
                if let result = controller.repairResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
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
