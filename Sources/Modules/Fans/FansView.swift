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
        .padding(.horizontal, 14).padding(.vertical, 8)
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
    /// Настройки «По датчику» вынесены в общий блок под карточками.
    let sharedSensor: Bool
    @Environment(\.dsTint) private var tint

    private var overridden: Bool { fullPower || gameName != nil }

    private var load: Double {
        guard fan.max > fan.min else { return 0 }
        return min(max((fan.actual - fan.min) / (fan.max - fan.min), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fan.isManual ? tint : dim)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
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
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "\(Int(fan.actual.rounded()))")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    Text("об/мин").font(.system(size: 11)).foregroundStyle(dim)
                }
            }

            LoadBar(value: load)

            DSSegmented(FanMode.allCases, selection: $config.mode) { $0.title }
                .frame(maxWidth: .infinity)
                .disabled(overridden)
                .opacity(overridden ? 0.5 : 1)

            modeArea
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.white.opacity(0.05)))
    }

    @ViewBuilder private var modeArea: some View {
        if fullPower {
            note("На максимуме: «Полная мощность». После неё вернётся «\(config.mode.title)».", color: .green)
        } else if let gameName {
            note("На максимуме: играешь в \(gameName). После игры вернётся «\(config.mode.title)».", color: .green)
        } else {
            switch config.mode {
            case .auto:
                note("Оборотами управляет macOS.").frame(minHeight: 20, alignment: .leading)

            case .constant:
                HStack(spacing: 8) {
                    // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                    Slider(value: Binding(
                        get: { config.rpm == 0 ? fan.min : min(max(config.rpm, fan.min), fan.max) },
                        set: {
                            // Слайдер шлёт событие на каждый пиксель; присваивать — только при смене шага.
                            let new = min(max(($0 / 100).rounded() * 100, fan.min), fan.max)
                            if new != config.rpm { config.rpm = new }
                        }
                    ), in: fan.min...fan.max)
                    .controlSize(.small).tint(tint)
                    Text(rpm(config.rpm == 0 ? fan.min : config.rpm))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 84, alignment: .trailing)
                }
                .frame(minHeight: 20)

            case .sensor:
                if sharedSensor {
                    note("\(config.sensor.title): \(Int(config.fromTemp))–\(Int(config.toTemp)) °C. Настройки ниже.")
                        .frame(minHeight: 20, alignment: .leading)
                } else {
                    SensorSettings(config: $config, cpuTemp: cpuTemp, gpuTemp: gpuTemp, compact: true)
                }
            }
        }
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
                .lineLimit(1).fixedSize()
            // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
            Slider(value: Binding(get: { value }, set: { let new = $0.rounded(); if new != value { value = new } }), in: range)
                .controlSize(.small).tint(tint)
            Text("\(Int(value)) °C").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// Датчик и границы «По датчику»: в общем блоке под карточками и внутри карточки, если режимы разные.
private struct SensorSettings: View {
    @Binding var config: FanConfig
    let cpuTemp: Double?
    let gpuTemp: Double?
    /// Внутри карточки слайдеры в столбик; в общем блоке — два в ряд.
    var compact = false

    private var nowText: String? {
        (config.sensor == .cpu ? cpuTemp : gpuTemp).map { "Сейчас \(Int($0.rounded())) °C" }
    }

    private var hint: String {
        "Ниже \(Int(config.fromTemp)) °C решает macOS, вентиляторы могут стоять. К \(Int(config.toTemp)) °C — максимум."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                // В общем блоке подсказка стоит в одной строке с датчиком — так он ниже на строку.
                if compact {
                    nowText.map { Text($0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
                } else {
                    (Text(nowText.map { $0 + ". " } ?? "").foregroundStyle(.white.opacity(0.85))
                        + Text("Ниже \(Int(config.fromTemp)) °C решает macOS, к \(Int(config.toTemp)) °C — максимум.").foregroundStyle(dim))
                        .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.9)
                }
                Spacer(minLength: 0)
                DSSegmented(SensorSource.allCases, selection: $config.sensor) { $0.title }
                    .frame(width: 190)
            }
            if compact {
                from
                to
                Text(hint).font(.system(size: 11)).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 24) { from; to }
            }
        }
    }

    private var from: some View {
        TempSlider(title: "Начинать с", value: $config.fromTemp, range: 30...(config.toTemp - 5))
    }
    private var to: some View {
        TempSlider(title: "Максимум при", value: $config.toTemp, range: (config.fromTemp + 5)...100)
    }
}

// MARK: - Карточка без заголовка

/// Та же карточка, что у `DSSection`, но без подписи над ней: экран должен влезать без прокрутки.
private struct FlatCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
            .clipShape(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.7))
    }
}

private struct Separator: View {
    var body: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
}

// MARK: - Температура

/// Одна строка «Процессор 58° · Видеокарта 51°»; по клику раскрываются все датчики.
private struct TemperatureCard: View {
    let cpu: [SensorReading]
    let gpu: [SensorReading]
    @State private var expanded = false
    @Environment(\.dsTint) private var tint

    private var summary: String {
        var parts: [String] = []
        if let v = cpu.map(\.value).max() { parts.append("Процессор \(String(format: "%.0f°", v))") }
        if let v = gpu.map(\.value).max() { parts.append("Видеокарта \(String(format: "%.0f°", v))") }
        return parts.isEmpty ? "нет датчиков" : parts.joined(separator: " · ")
    }

    var body: some View {
        FlatCard {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.18))
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "thermometer.medium").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint))
                    Text("Температура").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    Spacer(minLength: 10)
                    Text(summary).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                        .frame(width: 12)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cpu.isEmpty && gpu.isEmpty)
            .help(expanded ? "Скрыть датчики" : "Показать все датчики")

            if expanded {
                Separator()
                VStack(alignment: .leading, spacing: 10) {
                    group("Процессор", cpu)
                    group("Видеокарта", gpu)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ sensors: [SensorReading]) -> some View {
        if !sensors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) · датчиков: \(sensors.count)").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 6) {
                    ForEach(sensors) { s in
                        HStack(spacing: 6) {
                            Text(s.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(dim)
                            Text(celsius(s.value)).font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
        }
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

/// «Максимум в играх»: переключатель, свои игры плашками и лаунчеры-игры во всплывающем окне.
private struct GameModeCard: View {
    @ObservedObject var game: GameModeController
    @State private var launchersOpen = false
    @Environment(\.dsTint) private var tint

    private var gameLauncherCount: Int {
        GameRules.defaultLaunchers.filter { game.isLauncherGame($0.key) }.count
    }

    var body: some View {
        FlatCard {
            // Всё в одну строку: заголовок, «Добавить», лаунчеры и переключатель.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.18))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Максимум в играх").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    Text("Игра на переднем плане — вентиляторы на максимум")
                        .font(.system(size: 11.5)).foregroundStyle(dim).lineLimit(1)
                }
                Spacer(minLength: 10)
                if game.isEnabled {
                    addMenu
                    launchersLink
                }
                DSToggle("Максимум в играх", isOn: $game.isEnabled)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            // Вторая строка нужна только когда есть свои игры.
            if game.isEnabled && !game.myGames.isEmpty {
                Separator()
                ChipFlow(spacing: 6) {
                    ForEach(game.myGames) { entry in
                        GameChip(entry: entry, icon: game.icon(for: entry)) { game.removeGame(entry) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .onPageActive { if $0 { game.refreshRunning() } }
    }

    private var addMenu: some View {
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
                .help("Игры определяются сами; остальные, например из CrossOver, добавь сюда")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.1)))
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var launchersLink: some View {
        Button {
            launchersOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Лаунчеры: \(gameLauncherCount) из \(GameRules.defaultLaunchers.count)")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Отмеченный лаунчер считается игрой: пока он открыт, вентиляторы на максимуме")
        .popover(isPresented: $launchersOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Лаунчер = игра").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                    .padding(.bottom, 8)
                ForEach(GameRules.defaultLaunchers) { launcher in
                    HStack {
                        Text(launcher.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 16)
                        DSToggle(launcher.name, isOn: Binding(
                            get: { game.isLauncherGame(launcher.key) },
                            set: { game.setLauncherGame(launcher.key, $0) }
                        ))
                    }
                    .padding(.vertical, 5)
                }
                Text("Включённый лаунчер считается игрой: пока он открыт, вентиляторы на максимуме.")
                    .font(.system(size: 11.5)).foregroundStyle(dim).padding(.top, 6)
            }
            .padding(14).frame(width: 290)
            .dsThemed()
            .environment(\.dsTint, tint)
        }
    }
}

// MARK: - Экран

/// Экран модуля «Вентиляторы» — аналог Macs Fan Control.
/// Всё плотно, чтобы в обычном состоянии (два вентилятора, игры включены) страница не прокручивалась.
struct FansView: View {
    @ObservedObject var controller = FanController.shared
    @ObservedObject var installer = FanHelperInstaller.shared
    @ObservedObject var game = GameModeController.shared

    private var canControl: Bool { installer.status == .ready && controller.conflictingApp == nil }
    private var gameName: String? { game.isActive ? game.phase.gameName : nil }
    private var overridden: Bool { controller.fullPower || gameName != nil }

    /// У всех вентиляторов «По датчику» с одинаковыми настройками — они правятся одним блоком.
    private var sharedSensor: Bool {
        let cs = controller.configs
        guard controller.fans.count > 1, let first = cs.first, first.mode == .sensor else { return false }
        return cs.allSatisfy { $0.mode == .sensor && $0.sensor == first.sensor
            && $0.fromTemp == first.fromTemp && $0.toTemp == first.toTemp }
    }

    private var primary: DSAction? {
        // Без доступа или при конфликте кнопка ничего бы не сделала — не показываем.
        guard canControl else { return nil }
        return controller.fullPower
            ? DSAction("Выключить полную мощность", icon: "bolt.slash.fill") { controller.fullPower = false }
            : DSAction("Полная мощность", icon: "bolt.fill") { controller.fullPower = true }
    }

    var body: some View {
        DSPage(module: .fans, subtitle: controller.cpuMax.map { "Процессор \(celsius($0))" }, primary: primary) {
            // Один дочерний блок: между блоками страницы 20 pt, а тут хватает 10.
            VStack(alignment: .leading, spacing: 10) {
                banners
                fansSection
                TemperatureCard(cpu: controller.cpuSensors, gpu: controller.gpuSensors)
                GameModeCard(game: game)
                footer
            }
        }
        .onPageActive { if $0 { installer.refresh() } }
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
            if case .leaving = game.phase {
                // Секунды считаем от срока, а не от счётчика: экран перерисуется раз в секунду сам.
                // Тикает только пока идёт обратный отсчёт; в игре текст статичный.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Banner(icon: "gamecontroller.fill", color: .green, text: statusText(name: name, now: context.date)) {
                        EmptyView()
                    }
                }
            } else {
                Banner(icon: "gamecontroller.fill", color: .green, text: statusText(name: name, now: .now)) {
                    EmptyView()
                }
            }
        }
    }

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Заголовок как у DSSection, но «Всё авто» стоит в нём же: отдельная строка внизу не нужна.
            HStack(spacing: 10) {
                Text("ВЕНТИЛЯТОРЫ").font(DS.sectionTitle).tracking(0.8).foregroundStyle(.white.opacity(0.42))
                Spacer()
                if let rangeText {
                    Text(rangeText).font(.system(size: 11.5, weight: .medium)).foregroundStyle(dim)
                }
                DSButton("Всё авто", icon: "arrow.uturn.backward", small: true) { controller.setAllAuto() }
                    .help("Вернуть все вентиляторы в «Авто»: оборотами управляет macOS")
                    .disabled(!canControl)
            }
            .padding(.leading, 6)

            FlatCard {
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
                                        gameName: gameName, sharedSensor: sharedSensor)
                            }
                        }
                    }
                    .padding(10)

                    if sharedSensor && !overridden {
                        Separator()
                        SensorSettings(config: sharedConfig, cpuTemp: controller.cpuMax, gpuTemp: controller.gpuMax)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .disabled(!canControl)
                            .opacity(canControl ? 1 : 0.5)
                    }
                }
            }
        }
    }

    /// Общие настройки «По датчику»: читаются у первого вентилятора, пишутся всем сразу одним присваиванием.
    private var sharedConfig: Binding<FanConfig> {
        Binding(
            get: { controller.configs.first ?? FanConfig() },
            set: { new in
                controller.configs = controller.configs.map {
                    var c = $0
                    c.sensor = new.sensor; c.fromTemp = new.fromTemp; c.toTemp = new.toTemp
                    return c
                }
            }
        )
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
        VStack(alignment: .leading, spacing: 4) {
            if let error = controller.lastError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            HStack {
                Text("При выходе из Utilitumus вентиляторы возвращаются в «Авто».")
                    .font(.system(size: 11)).foregroundStyle(dim)
                Spacer()
                if installer.status != .notInstalled {
                    DSButton("Забрать доступ…", style: .plain, small: true) { installer.uninstall() }
                }
            }
        }
        .padding(.horizontal, 6)
    }
}
