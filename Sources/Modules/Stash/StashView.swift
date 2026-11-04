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
        .roundedFocusRing(10)
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

/// «Вернуть»: что именно вернётся — значки программ и сколько окон встанет на место.
private struct RestoreButton: View {
    let apps: [StashedApp]
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Вернуть \(programs(apps.count))").font(.title3.weight(.semibold))
                        Text(windowsSummary).font(.callout).opacity(0.8)
                    }
                    Spacer()
                }
                FlowLayout(spacing: 6) {
                    ForEach(apps) { app in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name).font(.callout.weight(.medium))
                            if app.windows.count > 1 {
                                Text("\(app.windows.count)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .padding(.horizontal, 5)
                                    .background(.white.opacity(0.25), in: Capsule())
                                    .help("Окон: \(app.windows.count)")
                            }
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 9)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                .padding(.leading, 50)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedFocusRing(10)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var windowsSummary: String {
        let windows = apps.reduce(0) { $0 + $1.windows.count }
        let verb = apps.count == 1 ? "Откроется" : "Откроются"
        guard windows > 0 else { return "\(verb) снова" }
        let mod100 = windows % 100, mod10 = windows % 10
        let word = (11...14).contains(mod100) ? "окон"
            : mod10 == 1 ? "окно" : (2...4).contains(mod10) ? "окна" : "окон"
        return "\(verb), и \(windows) \(word) \(word == "окно" ? "встанет" : "встанут") на своё место"
    }
}

/// Строки слева направо с переносом — для значков программ.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.items.isEmpty }
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
                    RestoreButton(apps: store.stashed, enabled: store.busy == nil) {
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
