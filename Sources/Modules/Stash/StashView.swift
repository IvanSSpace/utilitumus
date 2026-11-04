import SwiftUI

/// Большая кнопка в стиле «Полной мощности»: заголовок, пояснение, цвет действия.
private struct StashActionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).opacity(0.8)
                }
                Spacer()
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private func usageText(_ usage: AppUsage) -> String {
    let memory = usage.memoryMB >= 1024
        ? String(format: "%.1f ГБ", usage.memoryMB / 1024)
        : "\(Int(usage.memoryMB.rounded())) МБ"
    return "\(memory) · \(Int(usage.cpu.rounded())) %"
}

private struct AppLabel: View {
    let icon: NSImage?
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app").frame(width: 24, height: 24)
            }
            Text(name)
        }
    }
}

private func programs(_ n: Int) -> String {
    let mod100 = n % 100, mod10 = n % 10
    if (11...14).contains(mod100) { return "\(n) программ" }
    switch mod10 {
    case 1: return "\(n) программу"
    case 2...4: return "\(n) программы"
    default: return "\(n) программ"
    }
}

/// Экран модуля «Стеш программ».
struct StashView: View {
    @ObservedObject var store = StashStore.shared
    @State private var confirmStash = false

    private var selectedCount: Int { store.selected.count }

    var body: some View {
        Form {
            if !store.axTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Чтобы окна вернулись на свои места и экраны, дай Utilitumus «Универсальный доступ»",
                              systemImage: "lock.shield")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Дать доступ…") { store.requestAccess() }
                            .buttonStyle(.borderedProminent)
                        Text("Без доступа стеш и возврат работают, просто без запоминания окон.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                StashActionButton(
                    icon: "square.stack.3d.down.right.fill",
                    title: store.busy ?? "Спрятать всё",
                    subtitle: selectedCount == 0
                        ? "Отметь ниже, что закрывать"
                        : "Закрыть \(programs(selectedCount)) и запомнить, где стояли окна",
                    tint: .accentColor,
                    enabled: store.busy == nil && selectedCount > 0
                ) {
                    confirmStash = true
                }
                // Один промах мышью закрыл бы терминалы с работой — сначала список.
                .confirmationDialog("Закрыть \(programs(selectedCount))?", isPresented: $confirmStash) {
                    Button("Закрыть и спрятать", role: .destructive) {
                        Task { await store.stashSelected() }
                    }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text(store.selected.compactMap(\.localizedName).joined(separator: ", ")
                         + "\n\nНесохранённое программы спросят сами. Вернуть можно кнопкой «Вернуть».")
                }

                if !store.stashed.isEmpty {
                    StashActionButton(
                        icon: "arrow.uturn.backward.circle.fill",
                        title: "Вернуть \(programs(store.stashed.count))",
                        subtitle: store.stashed.map(\.name).joined(separator: ", "),
                        tint: .green,
                        enabled: store.busy == nil
                    ) {
                        Task { await store.restore() }
                    }
                }
            }

            if !store.stubborn.isEmpty {
                Section {
                    ForEach(store.stubborn) { entry in
                        HStack {
                            AppLabel(icon: entry.icon, name: entry.name)
                            Spacer()
                            Button("Закрыть принудительно") { store.forceTerminate(entry) }
                        }
                    }
                    HStack {
                        Text("Возможно, там несохранённые документы. Закрою только если нажмёшь.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Закрыть все принудительно", role: .destructive) { store.forceTerminateAll() }
                    }
                } header: {
                    Label("Не закрылись за 10 секунд", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let report = store.report {
                Section("Результат возврата") {
                    Label("Запущено: \(report.restored)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if report.hadAccess {
                        Text("Окон возвращено на место: \(report.windowsPlaced)")
                    } else {
                        Text("Окна на места не возвращались: нет доступа «Универсальный доступ».")
                            .foregroundStyle(.secondary)
                    }
                    if !report.missing.isEmpty {
                        Label("Нет на диске, пропущены: \(report.missing.joined(separator: ", "))",
                              systemImage: "questionmark.folder")
                            .foregroundStyle(.orange)
                    }
                    if !report.failed.isEmpty {
                        Label("Не удалось открыть: \(report.failed.joined(separator: ", "))",
                              systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                if store.running.isEmpty {
                    Text("Нет запущенных программ").foregroundStyle(.secondary)
                }
                ForEach(store.runningByWeight) { entry in
                    Toggle(isOn: Binding(
                        get: { store.isClosing(entry.bundleID) },
                        set: { store.setClosing(entry.bundleID, $0) }
                    )) {
                        HStack {
                            AppLabel(icon: entry.icon, name: entry.name)
                            if let usage = store.usage[entry.bundleID] {
                                if usage.isHeavy {
                                    Text("тяжёлая")
                                        .font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.25), in: Capsule())
                                }
                                Spacer()
                                Text(usageText(usage))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(usage.isHeavy ? .primary : .secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Закрывать")
                    Spacer()
                    if store.running.contains(where: { store.usage[$0.bundleID]?.isHeavy == true }) {
                        Button("Только тяжёлые") { store.selectOnlyHeavy() }
                            .buttonStyle(.link)
                            .font(.callout)
                            .help("Отметить к закрытию только программы от 1 ГБ памяти или от 25 % процессора")
                    }
                }
            } footer: {
                Text("Память и процессор — вместе со всеми процессами программы. Тяжёлая — от 1 ГБ или от 25 % процессора. Finder и сам Utilitumus не закрываются. Новая программа по умолчанию отмечена.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Стеш программ")
        .navigationSubtitle(store.stashed.isEmpty ? "" : "В стеше: \(store.stashed.count)")
        .onAppear { store.start() }
        // Замеры — только пока экран открыт.
        .task {
            while !Task.isCancelled {
                // Доступ дают в Системных настройках — заметить без возврата в окно.
                store.refreshAccess()
                await store.refreshUsage()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
