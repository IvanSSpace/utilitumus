import SwiftUI

private func rpm(_ v: Double) -> String { "\(Int(v.rounded())) об/мин" }
private func celsius(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }

private let dim = Color.white.opacity(0.5)

// MARK: - Плашка-сообщение

/// Заметное сообщение над страницей: доступ, конфликт, перегрев, «Полная мощность».
private struct Banner<Trailing: View>: View {
    let icon: String
    let color: Color
    let text: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                if let detail {
                    Text(detail).font(DS.rowSubtitle).foregroundStyle(dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(color.opacity(0.14)))
    }
}

// MARK: - Вентилятор

private struct LoadBar: View {
    let value: Double
    @Environment(\.dsTint) private var tint

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(tint).frame(width: max(g.size.width * value, 5))
            }
        }
        .frame(height: 5)
    }
}

private struct FanCard: View {
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
    @Environment(\.dsTint) private var tint

    private var overridden: Bool { fullPower || gameName != nil }

    private var load: Double {
        guard fan.max > fan.min else { return 0 }
        return min(max((fan.actual - fan.min) / (fan.max - fan.min), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(fan.isManual ? tint : dim)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Вентилятор \(fan.index + 1)").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    if fan.isSpinningUp {
                        DSChip("раскручивается до \(Int(fan.target.rounded()))", color: .green)
                    } else if fan.isManual {
                        DSChip("вручную", color: tint)
                    } else {
                        Text("авто").font(.system(size: 11, weight: .medium)).foregroundStyle(dim)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: "\(Int(fan.actual.rounded()))")
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    Text("об/мин").font(.system(size: 11)).foregroundStyle(dim)
                }
            }

            VStack(spacing: 4) {
                LoadBar(value: load)
                HStack {
                    Text(rpm(fan.min))
                    Spacer()
                    Text(rpm(fan.max))
                }
                .font(.system(size: 11)).foregroundStyle(dim).monospacedDigit()
            }

            DSSegmented(FanMode.allCases, selection: $config.mode) { $0.title }
                .frame(maxWidth: .infinity)
                .disabled(overridden)
                .opacity(overridden ? 0.5 : 1)

            if fullPower {
                note("На максимуме: «Полная мощность». После неё вернётся «\(config.mode.title)».", color: .green)
            } else if let gameName {
                note("На максимуме: играешь в \(gameName). После игры вернётся «\(config.mode.title)».", color: .green)
            } else {
                switch config.mode {
                case .auto:
                    note("Оборотами управляет macOS.")

                case .constant:
                    HStack(spacing: 8) {
                        // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                        Slider(value: Binding(
                            get: { config.rpm == 0 ? fan.min : min(max(config.rpm, fan.min), fan.max) },
                            set: { config.rpm = min(max(($0 / 100).rounded() * 100, fan.min), fan.max) }
                        ), in: fan.min...fan.max)
                        .controlSize(.small).tint(tint)
                        Text(rpm(config.rpm == 0 ? fan.min : config.rpm))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 92, alignment: .trailing)
                    }

                case .sensor:
                    DSSegmented(SensorSource.allCases, selection: $config.sensor) { $0.title }
                        .frame(maxWidth: .infinity)
                    TempSlider(title: "Разгон с", value: $config.fromTemp, range: 30...(config.toTemp - 5))
                    TempSlider(title: "Максимум при", value: $config.toTemp, range: (config.fromTemp + 5)...100)
                    if let now = (config.sensor == .cpu ? cpuTemp : gpuTemp) {
                        note("Сейчас \(Int(now.rounded())) °C — самый горячий датчик.")
                    }
                    note("Ниже \(Int(config.fromTemp)) °C решает macOS, вентиляторы могут стоять. К \(Int(config.toTemp)) °C — максимум.")
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func note(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color ?? dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TempSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 96, alignment: .leading)
            // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                .controlSize(.small).tint(tint)
            Text("\(Int(value)) °C").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Температура

private struct SensorGroup: View {
    let icon: String
    let title: String
    let sensors: [SensorReading]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                DSRow(icon: icon, title: title, subtitle: subtitle) {
                    if !sensors.isEmpty {
                        Text(celsius(sensors.map(\.value).max()))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.95))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sensors.isEmpty)
            .help(expanded ? "Скрыть датчики" : "Показать все датчики")

            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 6) {
                    ForEach(sensors) { s in
                        HStack(spacing: 6) {
                            Text(s.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(dim)
                            Text(celsius(s.value)).font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 12)
            }
        }
    }

    private var subtitle: String {
        guard !sensors.isEmpty else { return "нет датчиков" }
        let avg = sensors.map(\.value).reduce(0, +) / Double(sensors.count)
        return "средняя \(celsius(avg)) · датчиков: \(sensors.count)"
    }
}

// MARK: - Игры

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
            Text(entry.name).lineLimit(1).foregroundStyle(.white.opacity(0.9))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(dim)
            }
            .buttonStyle(.plain)
            .help("Убрать из списка")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.1)))
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

/// «Максимум в играх»: переключатель, список своих игр и лаунчеры-исключения.
private struct GameModeSection: View {
    @ObservedObject var game: GameModeController
    @State private var launchersOpen = false

    private var excludedCount: Int {
        GameRules.defaultLaunchers.filter { game.isLauncherExcluded($0.key) }.count
    }

    var body: some View {
        DSSection("Максимум в играх") {
            DSRow(icon: "gamecontroller.fill", title: "Максимум в играх",
                  subtitle: "Игра на переднем плане — вентиляторы сами идут на максимум") {
                DSToggle("Максимум в играх", isOn: $game.isEnabled)
            }

            if game.isEnabled {
                DSRow(title: "Мои игры",
                      subtitle: game.myGames.isEmpty
                        ? "Игры определяются сами. Остальные, например из CrossOver, добавь сюда." : nil) {
                    Menu {
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
                    } label: {
                        Text("Добавить…")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if !game.myGames.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(game.myGames) { entry in
                            GameChip(entry: entry, icon: game.icon(for: entry)) { game.removeGame(entry) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    launchersOpen.toggle()
                } label: {
                    DSRow(title: "Лаунчеры — не игры") {
                        Text("\(excludedCount) из \(GameRules.defaultLaunchers.count)")
                            .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(dim)
                        Image(systemName: launchersOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                            .frame(width: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if launchersOpen {
                    ForEach(GameRules.defaultLaunchers) { launcher in
                        DSRow(title: launcher.name) {
                            DSToggle(launcher.name, isOn: Binding(
                                get: { game.isLauncherExcluded(launcher.key) },
                                set: { game.setLauncherExcluded(launcher.key, $0) }
                            ))
                        }
                    }
                    Text("Лаунчер — не игра. Выключи, если нужно иначе.")
                        .font(.system(size: 11.5)).foregroundStyle(dim)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
        .onAppear { game.refreshRunning() }
    }
}

// MARK: - Экран

/// Экран модуля «Вентиляторы» — аналог Macs Fan Control.
struct FansView: View {
    @ObservedObject var controller = FanController.shared
    @ObservedObject var installer = FanHelperInstaller.shared
    @ObservedObject var game = GameModeController.shared

    private var canControl: Bool { installer.status != .notInstalled && controller.conflictingApp == nil }
    private var gameName: String? { game.isActive ? game.phase.gameName : nil }

    private var primary: DSAction? {
        // Без доступа или при конфликте кнопка ничего бы не сделала — не показываем.
        guard canControl else { return nil }
        return controller.fullPower
            ? DSAction("Выключить полную мощность", icon: "bolt.slash.fill") { controller.fullPower = false }
            : DSAction("Полная мощность", icon: "bolt.fill") { controller.fullPower = true }
    }

    var body: some View {
        DSPage(module: .fans, subtitle: controller.cpuMax.map { "Процессор \(celsius($0))" }, primary: primary) {
            banners
            fansSection
            GameModeSection(game: game)
            DSSection("Температура") {
                SensorGroup(icon: "cpu", title: "Процессор", sensors: controller.cpuSensors)
                SensorGroup(icon: "display", title: "Видеокарта", sensors: controller.gpuSensors)
            }
            footer
        }
        .onAppear { installer.refresh() }
    }

    @ViewBuilder private var banners: some View {
        // «Нужен доступ» теперь на экране «Осталось дать доступ»; здесь только устаревший помощник и ошибка.
        if installer.status == .outdated {
            Banner(icon: "lock.shield", color: .orange, text: "Доступ нужно обновить",
                   detail: "Помощник устарел. macOS один раз спросит пароль администратора.") {
                DSButton("Обновить доступ…", icon: "key.fill") { installer.install() }
            }
        }
        if let error = installer.lastError {
            Text(error).font(.system(size: 11.5)).foregroundStyle(.red).padding(.horizontal, 6)
        }

        if let app = controller.conflictingApp {
            Banner(icon: "exclamationmark.triangle.fill", color: .orange,
                   text: "\(app.localizedName ?? "Другая программа") управляет вентиляторами",
                   detail: "Пока она открыта, Utilitumus не вмешивается.") {
                DSButton("Закрыть её") { app.terminate() }
            }
        }

        if controller.safetyTripped && !controller.fullPower && !game.isActive {
            Banner(icon: "flame.fill", color: .red,
                   text: "Процессор горячее \(Int(FanController.safetyTrip)) °C",
                   detail: "Вентиляторы отданы системе, пока не остынет ниже \(Int(FanController.safetyRelease)) °C.") {
                EmptyView()
            }
        }

        if controller.fullPower {
            Banner(icon: "bolt.fill", color: .green, text: "Полная мощность включена",
                   detail: "Все вентиляторы на максимум, будет шумно.") { EmptyView() }
        } else if canControl, let name = gameName {
            // Секунды считаем от срока, а не от счётчика: экран перерисуется раз в секунду сам.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Banner(icon: "gamecontroller.fill", color: .green, text: statusText(name: name, now: context.date)) {
                    EmptyView()
                }
            }
        }
    }

    private var fansSection: some View {
        DSSection("Вентиляторы", trailing: rangeText) {
            DSRow(icon: "fan.fill", title: "Все вентиляторы",
                  subtitle: "Вернуть «Авто»: оборотами управляет macOS") {
                DSButton("Всё авто", icon: "arrow.uturn.backward", small: true) { controller.setAllAuto() }
                    .help("Вернуть все вентиляторы в «Авто»")
                    .disabled(!canControl)
            }
            if controller.fans.isEmpty {
                Text("Вентиляторы не найдены").font(DS.rowSubtitle).foregroundStyle(dim)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(controller.fans) { fan in
                        if fan.index < controller.configs.count {
                            FanCard(fan: fan, config: $controller.configs[fan.index], enabled: canControl,
                                    fullPower: controller.fullPower,
                                    cpuTemp: controller.cpuMax, gpuTemp: controller.gpuMax,
                                    gameName: gameName)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var rangeText: String? {
        guard let lo = controller.fans.map(\.min).min(), let hi = controller.fans.map(\.max).max() else { return nil }
        return "\(Int(lo.rounded())) – \(rpm(hi))"
    }

    private func statusText(name: String, now: Date) -> String {
        if case .leaving(_, let until) = game.phase {
            let left = max(Int(until.timeIntervalSince(now).rounded(.up)), 0)
            return "Максимум: играл в \(name), вернётся через \(left) с"
        }
        return "Максимум: играешь в \(name)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = controller.lastError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            HStack {
                Text("При выходе из Utilitumus вентиляторы возвращаются в «Авто».")
                    .font(.system(size: 11.5)).foregroundStyle(dim)
                Spacer()
                if installer.status != .notInstalled {
                    DSButton("Забрать доступ…", style: .plain, small: true) { installer.uninstall() }
                }
            }
        }
        .padding(.horizontal, 6)
    }
}
