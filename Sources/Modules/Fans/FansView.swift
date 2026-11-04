import SwiftUI

private func rpm(_ v: Double) -> String { "\(Int(v.rounded())) об/мин" }
private func celsius(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }

private struct FanRow: View {
    let fan: FanReading
    @Binding var config: FanConfig
    let enabled: Bool
    /// «Полная мощность» перебивает режим вентилятора — показываем это, а не
    /// «Оборотами управляет macOS», которое тогда было бы неправдой.
    let fullPower: Bool
    let cpuTemp: Double?
    let gpuTemp: Double?
    /// «Максимум в играх» перебивает режим так же; в подписи — во что играем.
    let gameName: String?

    private var overridden: Bool { fullPower || gameName != nil }

    private var load: Double {
        guard fan.max > fan.min else { return 0 }
        return min(max((fan.actual - fan.min) / (fan.max - fan.min), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(fan.isManual ? Color.accentColor : .secondary)
                Text("Вентилятор \(fan.index + 1)").font(.headline)
                if fan.isSpinningUp {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("раскручивается до \(rpm(fan.target))")
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.2), in: Capsule())
                } else if fan.isManual {
                    Text("вручную")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(rpm(fan.actual))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(value: load)
            HStack {
                Text(rpm(fan.min))
                Spacer()
                Text(rpm(fan.max))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            SegmentedControl(FanMode.allCases, selection: $config.mode) { $0.title }
            .disabled(overridden)
            .opacity(overridden ? 0.5 : 1)

            if fullPower {
                Text("На максимуме: «Полная мощность». После неё вернётся «\(config.mode.title)».")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let gameName {
                Text("На максимуме: играешь в \(gameName). После игры вернётся «\(config.mode.title)».")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                switch config.mode {
                case .auto:
                    Text("Оборотами управляет macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .constant:
                    HStack {
                        Slider(value: Binding(
                            get: { config.rpm == 0 ? fan.min : min(max(config.rpm, fan.min), fan.max) },
                            set: { config.rpm = $0 }
                        ), in: fan.min...fan.max, step: 100)
                        Text(rpm(config.rpm == 0 ? fan.min : config.rpm))
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }

                case .sensor:
                    Picker("Датчик", selection: $config.sensor) {
                        ForEach(SensorSource.allCases) { Text($0.title).tag($0) }
                    }
                    TempSlider(title: "Начинать разгон с", value: $config.fromTemp, range: 30...(config.toTemp - 5))
                    TempSlider(title: "Максимум при", value: $config.toTemp, range: (config.fromTemp + 5)...100)
                    if let now = (config.sensor == .cpu ? cpuTemp : gpuTemp) {
                        Text("Сейчас: \(Int(now.rounded())) °C (самый горячий датчик)")
                            .font(.caption.monospacedDigit())
                    }
                    Text("Ниже \(Int(config.fromTemp)) °C решает macOS, вентиляторы могут стоять. К \(Int(config.toTemp)) °C — максимум.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!enabled)
        .padding(.vertical, 4)
    }
}

private struct TempSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) °C").monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}

private struct SensorGroup: View {
    let title: String
    let sensors: [SensorReading]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 6) {
                ForEach(sensors) { s in
                    HStack(spacing: 6) {
                        Text(s.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(celsius(s.value)).font(.caption).monospacedDigit()
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if !sensors.isEmpty {
                    let avg = sensors.map(\.value).reduce(0, +) / Double(sensors.count)
                    Text("средн. \(celsius(avg))").foregroundStyle(.secondary)
                    Text("макс. \(celsius(sensors.map(\.value).max()))").monospacedDigit().fontWeight(.semibold)
                } else {
                    Text("нет датчиков").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Одна большая кнопка «всё на максимум» — перед игрой, без возни с режимами.
private struct FullPowerButton: View {
    @Binding var isOn: Bool
    let enabled: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 14) {
                // Включено — вентилятор крутится: оборот за 0.8 с. TimelineView,
                // а не repeatForever-анимация: та при выключении дёргается и не
                // останавливается чисто.
                TimelineView(.animation(paused: !isOn)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
                    Image(systemName: "fan.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .rotationEffect(.degrees(isOn ? turn * 360 : 0))
                }
                .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "Полная мощность включена" : "Полная мощность")
                        .font(.title3.weight(.semibold))
                    Text(isOn ? "Нажми, чтобы вернуть обычный режим" : "Все вентиляторы на максимум")
                        .font(.callout)
                        .opacity(0.8)
                }
                Spacer()
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(isOn ? Color.green : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedFocusRing(10)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

extension GameModeMachine.Phase {
    var gameName: String? {
        switch self {
        case .idle: return nil
        case .playing(let g), .leaving(let g, _): return g.name
        }
    }
}

private struct GameIcon: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "gamecontroller").frame(width: 20, height: 20)
        }
    }
}

/// Плашка своей игры: иконка, имя, крестик.
private struct GameChip: View {
    let entry: GameEntry
    let icon: NSImage?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            GameIcon(icon: icon).scaleEffect(0.8).frame(width: 16, height: 16)
            Text(entry.name).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать из списка")
        }
        .font(.callout)
        .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.14), in: Capsule())
        .help(entry.key.hasPrefix("exe:") ? String(entry.key.dropFirst(4)) : entry.name)
    }
}

/// Плашки переносятся на следующую строку, как слова в тексте.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in r.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}

/// «Максимум в играх»: переключатель, статус, список своих игр и лаунчеры-исключения.
private struct GameModeSection: View {
    @ObservedObject var game: GameModeController
    let canControl: Bool
    @State private var launchersOpen = false

    private var excludedCount: Int {
        GameRules.defaultLaunchers.filter { game.isLauncherExcluded($0.key) }.count
    }

    var body: some View {
        Section {
            Toggle(isOn: $game.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Максимум в играх")
                    Text("Когда игра на переднем плане, вентиляторы сами идут на максимум")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if game.isEnabled {
                if canControl, let name = game.phase.gameName {
                    // Секунды считаем от срока, а не от счётчика: экран перерисуется раз в секунду сам.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(statusText(name: name, now: context.date), systemImage: "gamecontroller.fill")
                            .foregroundStyle(.green)
                    }
                }

                HStack {
                    Text("Мои игры")
                    Spacer()
                    Menu("Добавить…") {
                        if game.addable.isEmpty {
                            Text("Нет запущенных программ")
                        }
                        ForEach(game.addable) { app in
                            Button {
                                game.addGame(app)
                            } label: {
                                if let icon = app.icon {
                                    Label { Text(app.name) } icon: { Image(nsImage: icon) }
                                } else {
                                    Text(app.name)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
                if game.myGames.isEmpty {
                    Text("Игры определяются сами. Остальные, например из CrossOver, добавь сюда.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ChipFlow(spacing: 6) {
                        ForEach(game.myGames) { entry in
                            GameChip(entry: entry, icon: game.icon(for: entry)) { game.removeGame(entry) }
                        }
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { launchersOpen.toggle() }
                } label: {
                    HStack {
                        Text("Лаунчеры — не игры")
                        Spacer()
                        Text("\(excludedCount) из \(GameRules.defaultLaunchers.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(launchersOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .roundedFocusRing(6)

                if launchersOpen {
                    ForEach(GameRules.defaultLaunchers) { launcher in
                        Toggle(launcher.name, isOn: Binding(
                            get: { game.isLauncherExcluded(launcher.key) },
                            set: { game.setLauncherExcluded(launcher.key, $0) }
                        ))
                    }
                    Text("Лаунчер — не игра. Сними галочку, если нужно иначе.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { game.refreshRunning() }
    }

    private func statusText(name: String, now: Date) -> String {
        if case .leaving(_, let until) = game.phase {
            let left = max(Int(until.timeIntervalSince(now).rounded(.up)), 0)
            return "Максимум: играл в \(name), вернётся через \(left) с"
        }
        return "Максимум: играешь в \(name)"
    }
}

/// Экран модуля «Вентиляторы» — аналог Macs Fan Control.
struct FansView: View {
    @ObservedObject var controller = FanController.shared
    @ObservedObject var installer = FanHelperInstaller.shared
    @ObservedObject var game = GameModeController.shared

    private var canControl: Bool { installer.status != .notInstalled && controller.conflictingApp == nil }

    var body: some View {
        Form {
            if installer.status != .ready {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(installer.status == .outdated ? "Доступ нужно обновить" : "Нужен доступ к вентиляторам",
                              systemImage: "lock.shield")
                            .font(.headline)
                        Text(installer.status == .outdated
                             ? "Помощник для вентиляторов устарел. macOS один раз спросит пароль администратора."
                             : "Менять обороты может только администратор. Utilitumus поставит помощника: macOS один раз спросит пароль или Touch ID.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(installer.status == .outdated ? "Обновить доступ…" : "Дать доступ…") {
                            installer.install()
                        }
                        .buttonStyle(.borderedProminent)
                        if let error = installer.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let app = controller.conflictingApp {
                Section {
                    HStack {
                        Label("\(app.localizedName ?? "Другая программа") управляет вентиляторами. Пока она открыта, Utilitumus не вмешивается.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Закрыть её") { app.terminate() }
                    }
                }
            }

            Section {
                FullPowerButton(isOn: $controller.fullPower, enabled: canControl)
            }

            if controller.safetyTripped && !controller.fullPower && !game.isActive {
                Section {
                    Label("Процессор горячее \(Int(FanController.safetyTrip)) °C: вентиляторы отданы системе, пока не остынет ниже \(Int(FanController.safetyRelease)) °C.",
                          systemImage: "flame.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Вентиляторы") {
                if controller.fans.isEmpty {
                    Text("Вентиляторы не найдены").foregroundStyle(.secondary)
                }
                ForEach(controller.fans) { fan in
                    if fan.index < controller.configs.count {
                        FanRow(fan: fan, config: $controller.configs[fan.index], enabled: canControl,
                               fullPower: controller.fullPower,
                               cpuTemp: controller.cpuMax, gpuTemp: controller.gpuMax,
                               gameName: game.isActive ? game.phase.gameName : nil)
                    }
                }
            }

            GameModeSection(game: game, canControl: canControl)

            Section("Температура") {
                SensorGroup(title: "Процессор", sensors: controller.cpuSensors)
                SensorGroup(title: "Видеокарта", sensors: controller.gpuSensors)
            }

            Section {
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("При выходе из Utilitumus вентиляторы возвращаются в «Авто».")
                    Spacer()
                    if installer.status != .notInstalled {
                        Button("Забрать доступ…") { installer.uninstall() }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Вентиляторы")
        .navigationSubtitle(controller.cpuMax.map { "Процессор \(celsius($0))" } ?? "")
        .toolbar {
            ToolbarItem {
                Button {
                    controller.setAllAuto()
                } label: {
                    // С подписью: голая стрелка читалась как «отменить».
                    Label("Всё авто", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .help("Вернуть все вентиляторы в «Авто»: оборотами управляет macOS")
                .disabled(!canControl)
            }
        }
        .onAppear { installer.refresh() }
    }
}
