import SwiftUI

/// Экран модуля «Не спать».
struct AwakeView<Model: AwakeModel>: View {
    @ObservedObject var model: Model

    var body: some View {
        DSPage(module: .awake, subtitle: "Mac не засыпает, пока ты работаешь") {
            DSSection("Сейчас") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isActive ? "Mac не уснёт" : "Mac засыпает как обычно")
                            .font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                        status
                    }
                    Spacer()
                    DSButton(model.isActive ? "Можно спать" : "Не спать сейчас",
                             icon: model.isActive ? "moon.zzz.fill" : "cup.and.saucer.fill",
                             style: model.isActive ? .secondary : .primary) { model.toggle() }
                        .disabled(!model.canStart && !model.isActive)
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }

            DSSection("Как долго") {
                // Отдельное окно уже страницы в центре: «Пока не выключу» в четырёх равных сегментах туда не влезает.
                ViewThatFits(in: .horizontal) {
                    DSRow(icon: "timer", title: "Длительность", subtitle: durationHint) {
                        DSSegmented(AwakeDuration.allCases, selection: $model.duration) { $0.title }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        DSRow(icon: "timer", title: "Длительность", subtitle: durationHint) { EmptyView() }
                        DSSegmented(AwakeDuration.allCases, selection: $model.duration) { $0 == .forever ? "Без срока" : $0.title }
                            .padding(.horizontal, 14).padding(.bottom, 10)
                    }
                }
                DSRow(icon: "display", title: "И экран не гаснет",
                      subtitle: "Иначе экран гаснет по таймеру системы, а Mac работает") {
                    DSToggle("И экран не гаснет", isOn: $model.keepDisplay)
                }
            }

            Text("С закрытой крышкой Mac всё равно уснёт: это требует прав администратора, модуль так не умеет.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 6)
        }
    }

    private var durationHint: String { "По истечении Mac снова может засыпать" }

    /// Остаток пересчитываем раз в секунду, пока экран открыт.
    @ViewBuilder private var status: some View {
        if let end = model.endDate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Осталось \(AwakeController.remainingText(until: end, now: context.date))")
                    .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
            }
        } else {
            Text(model.isActive ? "Пока не выключишь" : "Включи, когда нужно")
                .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
        }
    }
}
