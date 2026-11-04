import SwiftUI

/// Подтверждение остановки: что именно будет остановлено, что не тронем, и сколько это освободит.
struct StopConfirmSheet: View {
    @ObservedObject var store: LoadStore
    let plan: StopPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(plan.title).font(.title3.weight(.semibold))
                Spacer()
                Text("\(Fmt.plural(plan.targets.count, "процесс", "процесса", "процессов")) · ≈\(Fmt.mb(plan.totalMB))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Text(plan.message + " Сначала SIGTERM, через 5 с — SIGKILL.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Остановится:").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.targets.sorted { $0.memMB > $1.memMB }) { t in
                        HStack {
                            Text(t.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(String(t.pid)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(Fmt.mb(t.memMB)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)

            if !plan.kept.isEmpty {
                Text("Не тронем: " + plan.kept.prefix(5).map { "\($0.name) (\($0.why))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if store.stopRunning {
                    ProgressView().controlSize(.small)
                    Text("Останавливаю… до 5 с").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Enter по умолчанию отменяет: случайное нажатие ничего не остановит.
                Button("Отмена") { store.cancelStop() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.stopRunning)
                Button("Остановить", role: .destructive) { store.confirmStop() }
                    .disabled(store.stopRunning)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(store.stopRunning)
    }
}
