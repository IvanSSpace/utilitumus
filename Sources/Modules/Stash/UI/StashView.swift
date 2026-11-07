import SwiftUI

/// Программа на плашке: значок, имя, сколько окон (если больше одного).
struct StashChip: Identifiable {
    let id: String
    let icon: NSImage?
    let name: String
    var windows = 0
}

private struct ChipView: View {
    let chip: StashChip

    var body: some View {
        HStack(spacing: 5) {
            if let icon = chip.icon {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            }
            Text(chip.name).font(.system(size: 11.5, weight: .medium))
            if chip.windows > 1 {
                Text("\(chip.windows)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(.white.opacity(0.2), in: Capsule())
                    .help("Окон: \(chip.windows)")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(.white.opacity(0.12), in: Capsule())
    }
}

func memoryText(_ mb: Double) -> String {
    let text = mb >= 1024
        ? String(format: "%.1f ГБ", mb / 1024)
        : "\(Int(mb.rounded())) МБ"
    return text.replacingOccurrences(of: ".", with: ",")
}

private func usageText(_ usage: AppUsage) -> String {
    "\(memoryText(usage.memoryMB)) · \(Int(usage.cpu.rounded())) %"
}

private func appIcon(_ icon: NSImage?, size: CGFloat) -> some View {
    Group {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app").resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
        }
    }
    .frame(width: size, height: size)
}

/// Плитка программы: значок, имя и «Тяжёлая», под ними полоска памяти и цифры, справа тумблер.
/// Плитки встают в две колонки, поэтому цифры идут второй строкой.
private struct StashAppRow: View {
    let entry: StashProgram
    let usage: AppUsage?
    /// Доля памяти от самой тяжёлой программы (0…1).
    let share: Double
    let isOn: Binding<Bool>
    @Environment(\.dsTint) private var tint

    var body: some View {
        let heavy = usage?.isHeavy == true
        HStack(spacing: 10) {
            appIcon(entry.icon, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    if heavy { DSChip("Тяжёлая", color: .orange) }
                }
                if let usage {
                    HStack(spacing: 7) {
                        Capsule().fill(.white.opacity(0.1))
                            .frame(width: 44, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(heavy ? Color.orange : tint.opacity(0.7))
                                    .frame(width: max(4, 44 * share))
                            }
                        Text(usageText(usage))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(heavy ? Color.orange : .white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            DSToggle(entry.name, isOn: isOn)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous))
    }
}

/// Блок страницы со своей шапкой: справа можно положить кнопку, у `DSSection` там только текст.
private struct StashBlock<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @Environment(\.dsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title.uppercased()).font(DS.sectionTitle).tracking(0.8).foregroundStyle(.white.opacity(0.42))
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
                .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.7))
        }
    }
}

/// Карточка «Вернуть»: что именно вернётся — плашки программ и сколько окон встанет на место.
private struct RestoreCard: View {
    let apps: [StashProgram]
    let icons: [String: NSImage?]
    let enabled: Bool
    let action: () -> Void

    private let green = Color(hue: 0.38, saturation: 0.55, brightness: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(green.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(green))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вернуть \(programs(apps.count))").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    Text(windowsSummary).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 10)
                Button(action: action) {
                    Text("Вернуть").font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.78))
                        .padding(.horizontal, 17).padding(.vertical, 7)
                        .background(Capsule().fill(green))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            }
            FlowLayout(spacing: 5) {
                ForEach(apps) {
                    ChipView(chip: StashChip(id: $0.bundleID, icon: icons[$0.bundleID] ?? nil,
                                             name: $0.name, windows: $0.windowCount))
                }
            }
            .padding(.leading, 40)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(green.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
            .stroke(green.opacity(0.35), lineWidth: 0.8))
    }

    private var windowsSummary: String {
        let windows = apps.reduce(0) { $0 + $1.windowCount }
        let verb = apps.count == 1 ? "Откроется" : "Откроются"
        guard windows > 0 else { return "\(verb) снова" }
        let mod100 = windows % 100, mod10 = windows % 10
        let word = (11...14).contains(mod100) ? "окон"
            : mod10 == 1 ? "окно" : (2...4).contains(mod10) ? "окна" : "окон"
        return "\(verb), и \(windows) \(word) \(word == "окно" ? "встанет" : "встанут") на своё место"
    }
}

/// Карточка сценария: имя, значки программ и сколько из них запущено.
private struct ScenarioCard: View {
    let scenario: StashScenario
    let runningCount: Int
    let icons: [NSImage?]
    let enabled: Bool
    let action: () -> Void
    @Environment(\.dsTint) private var tint

    private static let maxIcons = 5

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(scenario.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    // Сколько программ сценария запущено сейчас.
                    Text("\(runningCount) из \(scenario.bundleIDs.count)")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: -4) {
                    ForEach(Array(icons.prefix(Self.maxIcons).enumerated()), id: \.offset) { _, icon in
                        appIcon(icon, size: 20)
                    }
                    if icons.count > Self.maxIcons {
                        Text("+\(icons.count - Self.maxIcons)")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.leading, 8)
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minWidth: 140, alignment: .leading)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedFocusRing(DS.rowRadius)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(enabled ? "Спрятать запущенные программы сценария" : "Ни одна программа сценария не запущена")
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

/// Число и слово «программа» в нужной форме; тот же текст и на дашборде в диалоге подтверждения.
func programs(_ n: Int) -> String {
    let mod100 = n % 100, mod10 = n % 10
    if (11...14).contains(mod100) { return "\(n) программ" }
    switch mod10 {
    case 1: return "\(n) программу"
    case 2...4: return "\(n) программы"
    default: return "\(n) программ"
    }
}

/// Экран модуля «Стеш программ».
struct StashView<Model: StashModel>: View {
    @Environment(\.pageActive) private var pageActive
    @ObservedObject var store: Model
    @State private var confirmStash = false
    @State private var pendingScenario: StashScenario?
    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""

    init(store: Model) { self.store = store }

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

    private var selectedCount: Int { store.selectedBundleIDs.count }

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

    private var subtitle: String {
        if let busy = store.busy { return busy }
        if store.runningPrograms.isEmpty { return "Нет запущенных программ" }
        let freed = store.selectedBundleIDs.reduce(0.0) { $0 + (store.usage[$1]?.memoryMB ?? 0) }
        let tail = freed > 0 ? " · освободится ≈ \(memoryText(freed))" : ""
        return "Выбрано \(selectedCount) из \(store.runningPrograms.count)\(tail)"
    }

    /// Плитки программ в две колонки (одна, если окно узкое). Длинный список прокручивается сам,
    /// чтобы остальная страница стояла на месте; строк до прокрутки меньше, когда сверху карточка «Вернуть».
    private var programsSection: some View {
        let entries = store.programsByWeight
        let maxMB = max(entries.compactMap { store.usage[$0.bundleID]?.memoryMB }.max() ?? 1, 1)
        let hasHeavy = entries.contains { store.usage[$0.bundleID]?.isHeavy == true }
        let maxRows: CGFloat = store.stashedPrograms.isEmpty ? 7 : 4
        let rowStep: CGFloat = 48 + 6
        return StashBlock(title: "Программы") {
            Text("Finder и Utilitumus не закрываются")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
            if hasHeavy {
                DSButton("Только тяжёлые", icon: "flame", small: true) { store.selectOnlyHeavy() }
                    .help("Оставить отмеченными только тяжёлые программы: от 1 ГБ памяти или 25 % процессора")
            }
        } content: {
            if entries.isEmpty {
                Text("Нет запущенных программ")
                    .font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    .padding(14)
            } else {
                let grid = LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 6)], spacing: 6) {
                    ForEach(entries) { entry in
                        let usage = store.usage[entry.bundleID]
                        StashAppRow(
                            entry: entry,
                            usage: usage,
                            share: (usage?.memoryMB ?? 0) / maxMB,
                            isOn: Binding(
                                get: { store.isClosing(entry.bundleID) },
                                set: { store.setClosing(entry.bundleID, $0) }
                            )
                        )
                    }
                }
                .padding(8)
                // Две колонки: больше maxRows рядов — прокрутка только внутри списка.
                if entries.count > Int(maxRows) * 2 {
                    DSScroll(inset: 6) { grid }
                        .frame(height: maxRows * rowStep + 10)
                } else {
                    grid
                }
            }
        }
    }

    private var scenariosSection: some View {
        StashBlock(title: "Сценарии") {
            DSButton("Сохранить как сценарий", icon: "plus", small: true) { ask(.new) }
                .disabled(selectedCount == 0)
                .help(selectedCount == 0 ? "Сначала отметь программы выше" : "Запомнить отмеченные программы под именем")
        } content: {
            if store.scenarios.isEmpty {
                Text("Сохрани набор программ и прячь его одним нажатием")
                    .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.scenarios) { scenario in
                        let alive = store.runningPrograms(of: scenario).count
                        ScenarioCard(
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
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var body: some View {
        DSPage(
            module: .stash,
            subtitle: subtitle,
            primary: DSAction(store.busy == nil ? "Спрятать выбранные" : "Прячу…", icon: "eye.slash.fill") {
                if store.busy == nil, selectedCount > 0 { confirmStash = true }
            }
        ) {
            if !store.stashedPrograms.isEmpty {
                RestoreCard(apps: store.stashedPrograms,
                            icons: Dictionary(uniqueKeysWithValues: store.stashedPrograms.map { ($0.bundleID, $0.icon) }),
                            enabled: store.busy == nil) {
                    Task { await store.restore() }
                }
            }

            if !store.stubbornPrograms.isEmpty {
                DSSection("Не закрылись за 10 секунд") {
                    ForEach(store.stubbornPrograms) { entry in
                        HStack(spacing: 12) {
                            appIcon(entry.icon, size: 30)
                            Text(entry.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                            Spacer(minLength: 10)
                            DSButton("Закрыть принудительно", small: true) { store.forceTerminate(entry.bundleID) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(minHeight: 50)
                        .overlay(alignment: .top) {
                            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 56)
                        }
                    }
                    DSRow(icon: "exclamationmark.triangle.fill", title: "Несохранённое пропадёт",
                          subtitle: "Закроется только по кнопке") {
                        DSButton("Закрыть все принудительно", small: true) { store.forceTerminateAll() }
                    }
                }
            }

            if let report = store.report {
                DSSection("Результат возврата") {
                    DSRow(icon: "checkmark.circle.fill", title: "Запущено: \(report.restored)")
                    if report.hadAccess {
                        DSRow(icon: "macwindow", title: "Окон возвращено на место: \(report.windowsPlaced)")
                    } else {
                        DSRow(icon: "macwindow", title: "Окна на места не вернулись",
                              subtitle: "Нет «Универсального доступа»")
                    }
                    if !report.missing.isEmpty {
                        DSRow(icon: "questionmark.folder", title: "Нет на диске, пропущены",
                              subtitle: report.missing.joined(separator: ", "))
                    }
                    if !report.failed.isEmpty {
                        DSRow(icon: "xmark.octagon.fill", title: "Не удалось открыть",
                              subtitle: report.failed.joined(separator: ", "))
                    }
                }
            }

            programsSection

            scenariosSection
        }
        // Один промах мышью закрыл бы терминалы с работой — сначала список.
        .confirmationDialog("Закрыть \(programs(selectedCount))?", isPresented: $confirmStash) {
            Button("Закрыть и спрятать", role: .destructive) {
                Task { await store.stashSelected() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(store.selectedNames.joined(separator: ", ")
                 + "\n\nНесохранённое программы спросят сами.")
        }
        .confirmationDialog(
            "Закрыть \(programs(pendingScenario.map { store.runningPrograms(of: $0).count } ?? 0))?",
            isPresented: Binding(get: { pendingScenario != nil }, set: { if !$0 { pendingScenario = nil } }),
            presenting: pendingScenario
        ) { scenario in
            Button("Закрыть и спрятать", role: .destructive) {
                Task { await store.stash(scenario) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { scenario in
            Text(store.runningPrograms(of: scenario).map(\.name).joined(separator: ", ")
                 + "\n\nНесохранённое программы спросят сами.")
        }
        .alert(namePromptTitle, isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
            TextField("Название", text: $nameText)
            Button("Сохранить") { commitName() }
            Button("Отмена", role: .cancel) {}
        }
        .onPageActive { if $0 { store.start() } }
        // Замеры — только пока страница показана.
        .task(id: pageActive) {
            while pageActive, !Task.isCancelled {
                // Доступ дают в Системных настройках — заметить без возврата в окно.
                store.refreshAccess()
                await store.refreshUsage()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
