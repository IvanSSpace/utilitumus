import SwiftUI

/// Большая кнопка в стиле «Полной мощности»: заголовок, пояснение и плашки программ,
/// чтобы было видно, что именно закроется или вернётся.
private struct ClassicStashActionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var chips: [StashChip] = []
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
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
                if !chips.isEmpty {
                    ClassicFlowLayout(spacing: 6) {
                        ForEach(chips) { ClassicChipView(chip: $0) }
                    }
                    .padding(.leading, 50)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedFocusRing(10)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct ClassicChipView: View {
    let chip: StashChip

    var body: some View {
        HStack(spacing: 6) {
            if let icon = chip.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(chip.name).font(.callout.weight(.medium))
            if chip.windows > 1 {
                Text("\(chip.windows)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(.white.opacity(0.25), in: Capsule())
                    .help("Окон: \(chip.windows)")
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(.white.opacity(0.18), in: Capsule())
    }
}

private func usageText(_ usage: AppUsage) -> String {
    let memory = usage.memoryMB >= 1024
        ? String(format: "%.1f ГБ", usage.memoryMB / 1024)
        : "\(Int(usage.memoryMB.rounded())) МБ"
    return "\(memory) · \(Int(usage.cpu.rounded())) %"
}

private struct ClassicAppLabel: View {
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
private struct ClassicRestoreButton: View {
    let apps: [StashedApp]
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        ClassicStashActionButton(
            icon: "arrow.uturn.backward.circle.fill",
            title: "Вернуть \(programs(apps.count))",
            subtitle: windowsSummary,
            tint: .green,
            chips: apps.map {
                StashChip(id: $0.bundleID, icon: NSWorkspace.shared.icon(forFile: $0.path),
                          name: $0.name, windows: $0.windows.count)
            },
            enabled: enabled,
            action: action
        )
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

/// Карточка сценария: имя, значки программ и сколько из них запущено.
private struct ClassicScenarioCard: View {
    let scenario: StashScenario
    let runningCount: Int
    let icons: [NSImage?]
    let enabled: Bool
    let action: () -> Void

    private static let maxIcons = 5

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(scenario.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: -4) {
                    ForEach(Array(icons.prefix(Self.maxIcons).enumerated()), id: \.offset) { _, icon in
                        if let icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app").frame(width: 22, height: 22)
                        }
                    }
                    if icons.count > Self.maxIcons {
                        Text("+\(icons.count - Self.maxIcons)")
                            .font(.caption.weight(.semibold))
                            .padding(.leading, 8)
                    }
                }
                Text("Запущено \(runningCount) из \(scenario.bundleIDs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 130, alignment: .leading)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedFocusRing(10)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(enabled ? "Спрятать запущенные программы сценария" : "Ни одна программа сценария не запущена")
    }
}

/// Строки слева направо с переносом — для значков программ.
private struct ClassicFlowLayout: Layout {
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

// programs(_:) — общий, из Sources/Modules/Stash/StashView.swift.

/// Экран модуля «Стеш программ».
struct ClassicStashView: View {
    @ObservedObject var store = StashStore.shared
    @State private var confirmStash = false
    @State private var pendingScenario: StashScenario?
    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""

    private enum NamePrompt: Identifiable {
        case new
        case rename(StashScenario)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let s): return s.id.uuidString
            }
        }
    }

    private var selectedCount: Int { store.selected.count }

    private var namePromptTitle: String {
        if case .rename = namePrompt { return "Новое имя сценария" }
        return "Сохранить как сценарий"
    }

    private func commitName() {
        switch namePrompt {
        case .new: store.addScenario(name: nameText)
        case .rename(let scenario): store.renameScenario(scenario.id, to: nameText)
        case nil: break
        }
        namePrompt = nil
    }

    private func ask(_ prompt: NamePrompt) {
        if case .rename(let scenario) = prompt { nameText = scenario.name } else { nameText = "" }
        namePrompt = prompt
    }

    private var scenariosSection: some View {
        Section {
            if !store.scenarios.isEmpty {
                ClassicFlowLayout(spacing: 8) {
                    ForEach(store.scenarios) { scenario in
                        let alive = store.runningApps(of: scenario).count
                        ClassicScenarioCard(
                            scenario: scenario,
                            runningCount: alive,
                            icons: scenario.bundleIDs.map { store.icon(forBundleID: $0) },
                            enabled: store.busy == nil && alive > 0
                        ) {
                            pendingScenario = scenario
                        }
                        .contextMenu {
                            Button("Выбрать эти программы") { store.select(scenario) }
                            Button("Обновить из текущего выбора") { store.updateScenario(scenario.id) }
                                .disabled(selectedCount == 0)
                            Button("Переименовать…") { ask(.rename(scenario)) }
                            Divider()
                            Button("Удалить", role: .destructive) { store.deleteScenario(scenario.id) }
                        }
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("Сохрани набор программ и прячь его одним нажатием.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Сценарии")
                Spacer()
                Button("Сохранить как сценарий…") { ask(.new) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(selectedCount == 0)
                    .help(selectedCount == 0 ? "Сначала отметь программы ниже" : "Запомнить отмеченные программы под именем")
            }
        }
    }

    var body: some View {
        Form {
            if !store.axTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Чтобы окна вернулись на места, дай Utilitumus «Универсальный доступ»",
                              systemImage: "lock.shield")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Дать доступ…") { store.requestAccess() }
                            .buttonStyle(.borderedProminent)
                        Text("Без доступа окна не запоминаются, остальное работает.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ClassicStashActionButton(
                    icon: "square.stack.3d.down.right.fill",
                    title: store.busy ?? "Спрятать выбранное",
                    subtitle: store.running.isEmpty ? "Нечего прятать"
                        : selectedCount == 0
                        ? "Отметь ниже, что закрывать"
                        : "Закрыть \(programs(selectedCount)) и запомнить, где стояли окна",
                    tint: .accentColor,
                    chips: store.selected.map {
                        StashChip(id: $0.bundleIdentifier ?? "\($0.processIdentifier)", icon: $0.icon,
                                  name: $0.localizedName ?? "Программа")
                    },
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
                         + "\n\nНесохранённое программы спросят сами.")
                }

                if !store.stashed.isEmpty {
                    ClassicRestoreButton(apps: store.stashed, enabled: store.busy == nil) {
                        Task { await store.restore() }
                    }
                }
            }

            scenariosSection

            if !store.stubborn.isEmpty {
                Section {
                    ForEach(store.stubborn) { entry in
                        HStack {
                            ClassicAppLabel(icon: entry.icon, name: entry.name)
                            Spacer()
                            Button("Закрыть принудительно") { store.forceTerminate(entry) }
                        }
                    }
                    HStack {
                        Text("Несохранённое пропадёт. Закроется только по кнопке.")
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
                        Text("Окна на места не вернулись: нет «Универсального доступа».")
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
                            ClassicAppLabel(icon: entry.icon, name: entry.name)
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
                            .help("Отметить программы от 1 ГБ памяти или 25 % процессора")
                    }
                }
            } footer: {
                Text("Тяжёлая — от 1 ГБ памяти или 25 % процессора. Finder и Utilitumus не закрываются.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Закрыть \(programs(pendingScenario.map { store.runningApps(of: $0).count } ?? 0))?",
            isPresented: Binding(get: { pendingScenario != nil }, set: { if !$0 { pendingScenario = nil } }),
            presenting: pendingScenario
        ) { scenario in
            Button("Закрыть и спрятать", role: .destructive) {
                Task { await store.stash(scenario) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { scenario in
            Text(store.runningApps(of: scenario).map(\.name).joined(separator: ", ")
                 + "\n\nНесохранённое программы спросят сами.")
        }
        .alert(namePromptTitle, isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
            TextField("Название", text: $nameText)
            Button("Сохранить") { commitName() }
            Button("Отмена", role: .cancel) {}
        }
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
