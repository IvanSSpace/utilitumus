import SwiftUI

/// Экран модуля «Не спать».
struct AwakeView: View {
    @ObservedObject var controller = AwakeController.shared

    var body: some View {
        DSPage(module: .awake, subtitle: "Mac не засыпает, пока ты работаешь") {
            DSSection("Сейчас") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.isActive ? "Mac не уснёт" : "Mac засыпает как обычно")
                            .font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                        status
                    }
                    Spacer()
                    DSButton(controller.isActive ? "Можно спать" : "Не спать сейчас",
                             icon: controller.isActive ? "moon.zzz.fill" : "cup.and.saucer.fill",
                             style: controller.isActive ? .secondary : .primary) { controller.toggle() }
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }

            DSSection("Как долго") {
                DSRow(icon: "timer", title: "Длительность",
                      subtitle: "По истечении Mac снова может засыпать") {
                    DSSegmented(AwakeDuration.allCases, selection: $controller.duration) { $0.title }
                }
                DSRow(icon: "display", title: "И экран не гаснет",
                      subtitle: "Иначе экран гаснет по таймеру системы, а Mac работает") {
                    DSToggle("И экран не гаснет", isOn: $controller.keepDisplay)
                }
            }

            Text("С закрытой крышкой Mac всё равно уснёт: это требует прав администратора, модуль так не умеет.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 6)
        }
    }

    /// Остаток пересчитываем раз в секунду, пока экран открыт.
    @ViewBuilder private var status: some View {
        if let end = controller.endDate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Осталось \(AwakeController.remainingText(until: end, now: context.date))")
                    .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
            }
        } else {
            Text(controller.isActive ? "Пока не выключишь" : "Включи, когда нужно")
                .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
        }
    }
}
