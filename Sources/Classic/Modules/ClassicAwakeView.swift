import SwiftUI

/// Экран модуля «Не спать» — классический интерфейс.
struct ClassicAwakeView: View {
    @ObservedObject var controller = AwakeController.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.isActive ? "Mac не уснёт" : "Mac засыпает как обычно").fontWeight(.medium)
                        if let end = controller.endDate {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("Осталось \(AwakeController.remainingText(until: end, now: context.date))")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button(controller.isActive ? "Можно спать" : "Не спать сейчас") { controller.toggle() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                LabeledContent("Длительность") {
                    SegmentedControl(AwakeDuration.allCases, selection: $controller.duration) { $0.title }
                }
                Toggle("И экран не гаснет", isOn: $controller.keepDisplay)
            } footer: {
                Text("С закрытой крышкой Mac всё равно уснёт: это требует прав администратора.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Не спать")
    }
}
