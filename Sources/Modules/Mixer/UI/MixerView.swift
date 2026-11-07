import SwiftUI

/// Разделитель между строками карточки — как в `DSRow`, но строка ниже (38 вместо 50 pt),
/// чтобы микшер целиком помещался в стандартное окно.
private struct RowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(minHeight: 38)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 46)
            }
    }
}

private struct AppIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().frame(width: 26, height: 26)
    }
}

/// Строка получает значения и замыкания, а не контроллер: иначе каждая публикация
/// контроллера перерисовывала бы все строки. `Equatable` по `app` пропускает
/// пересчёт, когда у строки ничего не поменялось.
private struct MixerRow: View, Equatable {
    let app: MixerApp
    let onVolume: (Double) -> Void
    let onCommit: () -> Void
    let onToggleMute: () -> Void
    let onEqualizer: (MixerEqSetting) -> Void
    @Environment(\.dsTint) private var tint
    /// Значение под пальцем: слайдер двигается сразу, а список публикуется позже.
    @State private var dragging: Double?
    @State private var eqOpen = false
    /// То же для регуляторов эквалайзера.
    @State private var draggingEq: MixerEqSetting?

    static func == (a: MixerRow, b: MixerRow) -> Bool { a.app == b.app }

    private var shownVolume: Double { dragging ?? app.volume }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            if eqOpen, let eq = draggingEq ?? app.eq {
                EqualizerPanel(setting: eq, onChange: { setting in
                    draggingEq = setting
                    onEqualizer(setting)
                }, onCommit: {
                    onCommit()
                    draggingEq = nil
                })
                .padding(.top, 6).padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .modifier(RowDivider())
        .onChange(of: app.volume) { dragging = nil }
        .onChange(of: app.eq) { draggingEq = nil }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                if app.muted {
                    Text("без звука").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 150, alignment: .leading)

            Slider(value: Binding(
                get: { shownVolume },
                // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                set: {
                    let value = ($0 * 100).rounded() / 100
                    dragging = value
                    onVolume(value)
                }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing { onCommit(); dragging = nil }
            })
            .tint(tint)
            .controlSize(.small)
            .opacity(app.muted ? 0.4 : 1)

            Text("\(Int((shownVolume * 100).rounded())) %")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, alignment: .trailing)

            // Нет значений — на той стороне старый Микшер, кнопки нет.
            if let eq = app.eq {
                EqualizerButton(active: (draggingEq ?? eq).isActive, open: eqOpen) {
                    withAnimation(.easeOut(duration: 0.15)) { eqOpen.toggle() }
                }
            }

            Button {
                onToggleMute()
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(app.muted ? Color.red : .white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(app.muted ? "Вернуть звук" : "Выключить звук")
        }
    }
}

/// Кнопка эквалайзера в строке: размер постоянный, активный вид меняет только цвет и подложку, раскладка стоит на месте.
private struct EqualizerButton: View {
    let active: Bool
    let open: Bool
    let action: () -> Void
    @Environment(\.dsTint) private var tint

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? tint : .white.opacity(open ? 0.85 : 0.6))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? tint.opacity(0.18) : .white.opacity(open ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(active ? "Эквалайзер включён" : "Эквалайзер")
    }
}

/// Раскрытая часть строки, на всю её ширину: выключатель и режим, ниже регуляторы полос.
private struct EqualizerPanel: View {
    let setting: MixerEqSetting
    let onChange: (MixerEqSetting) -> Void
    let onCommit: () -> Void

    private func change(_ next: MixerEqSetting) {
        onChange(next)
        onCommit()
    }

    private var presetTitle: String { MixerEq.presets.first { $0.id == setting.preset }?.title ?? "" }

    private var presetMenu: some View {
        Menu {
            ForEach(MixerEq.presets, id: \.id) { preset in
                Button {
                    change(setting.choosing(preset))
                } label: {
                    if preset.id == setting.preset { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(presetTitle).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DSToggle("Эквалайзер", isOn: Binding(get: { setting.enabled }, set: {
                    var next = setting
                    next.enabled = $0
                    change(next)
                }))
                Text("Эквалайзер").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text("Режим").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
                    presetMenu
                }
                .disabled(!setting.enabled)
                .opacity(setting.enabled ? 1 : 0.5)
            }
            HStack(spacing: 0) {
                ForEach(0..<MixerEq.bandCount, id: \.self) { band in
                    EqualizerSlider(title: MixerEq.bandTitles[band], value: setting.bands[band], onChange: { value in
                        onChange(setting.editing(band: band, to: value))
                    }, onCommit: onCommit)
                    .frame(maxWidth: .infinity)
                }
            }
            // Выключенный эквалайзер виден, но не правится: значения ждут включения.
            .allowsHitTesting(setting.enabled)
            .opacity(setting.enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: setting.enabled)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
    }
}

/// Вертикальный регулятор с насечками и средней линией. Свой, а не повёрнутый `Slider`: у того на macOS 26 меняются размеры и засечки.
/// Двигается относительно места нажатия, поэтому щелчок значение не меняет, а двойной щелчок возвращает 0.
private struct EqualizerSlider: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    @State private var dragStart: Double?

    private static let height: CGFloat = 92
    private static let knob: CGFloat = 16
    private static let span = MixerEq.maxGain - MixerEq.minGain

    private func y(_ gain: Double) -> CGFloat {
        Self.knob / 2 + CGFloat((MixerEq.maxGain - gain) / Self.span) * (Self.height - Self.knob)
    }

    private func clamped(_ raw: Double) -> Double {
        min(max((raw / MixerEq.step).rounded() * MixerEq.step, MixerEq.minGain), MixerEq.maxGain)
    }

    private var shownValue: String {
        value == 0 ? "0" : (value > 0 ? "+" : "−") + abs(value).formatted(.number.precision(.fractionLength(0...1)))
    }

    private var scale: some View {
        Canvas { context, size in
            let x = size.width / 2
            context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: 0, width: 3, height: size.height), cornerRadius: 1.5), with: .color(.white.opacity(0.18)))
            // Насечки по обе стороны дорожки каждые 3 дБ, через одну длиннее, и средняя линия на нуле.
            for gain in stride(from: MixerEq.minGain, through: MixerEq.maxGain, by: 3) where gain != 0 {
                let long = gain.truncatingRemainder(dividingBy: 6) == 0
                let width: CGFloat = long ? 5 : 3
                let line = y(gain)
                for side in [x - 7 - width, x + 7] {
                    context.fill(Path(CGRect(x: side, y: line - 0.5, width: width, height: 1)), with: .color(.white.opacity(long ? 0.26 : 0.16)))
                }
            }
            context.fill(Path(CGRect(x: x - 12, y: y(0) - 0.75, width: 24, height: 1.5)), with: .color(.white.opacity(0.6)))
            let here = y(value)
            context.fill(Path(ellipseIn: CGRect(x: x - Self.knob / 2, y: here - Self.knob / 2, width: Self.knob, height: Self.knob)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: here - 3, width: 6, height: 6)), with: .color(.black.opacity(0.8)))
        }
        .frame(width: 40, height: Self.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? value
                dragStart = start
                let next = clamped(start - Double(drag.translation.height / (Self.height - Self.knob)) * Self.span)
                if next != value { onChange(next) }
            }
            .onEnded { _ in
                dragStart = nil
                onCommit()
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if value != 0 { onChange(0) }
            onCommit()
        })
        .help("\(title) Гц: \(shownValue) дБ. Двойной щелчок вернёт 0")
        .accessibilityElement()
        .accessibilityLabel("\(title) герц")
        .accessibilityValue("\(shownValue) дБ")
        .accessibilityAdjustableAction { direction in
            onChange(clamped(value + (direction == .increment ? 1 : -1)))
            onCommit()
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            scale
            VStack(spacing: 0) {
                Text(title).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                Text("Гц").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

/// Приложение не запущено, но для него задана громкость: можно только сбросить.
private struct PresetRow: View, Equatable {
    let app: MixerApp
    let onReset: () -> Void

    static func == (a: PresetRow, b: PresetRow) -> Bool { a.app == b.app }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
            Spacer(minLength: 6)
            if app.eq?.isActive == true {
                Image(systemName: "slider.vertical.3").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).help("Настроен эквалайзер")
            }
            Text(app.muted ? "без звука" : "\(Int((app.volume * 100).rounded())) %")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            DSButton("Сбросить", small: true) { onReset() }
        }
        .modifier(RowDivider())
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
    }
}

/// Сворачивающая строка «Остальных»: компактная, подсказка вместо пояснения.
private struct OthersToggle: View {
    let expanded: Bool
    let count: Int
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "square.stack").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint))
            Text(expanded ? "Скрыть (\(count))" : "Показать (\(count))").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 6)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .modifier(RowDivider())
        .contentShape(Rectangle())
    }
}

struct MixerView<Model: MixerModel>: View {
    @ObservedObject var model: Model
    @State private var showOthers = false

    init(model: Model) { self.model = model }

    private func row(_ app: MixerApp) -> some View {
        let id = app.id
        return MixerRow(
            app: app,
            onVolume: { model.setVolume($0, for: id) },
            onCommit: { model.commitVolumes() },
            onToggleMute: { model.setMuted(!model.isMuted(id), for: id) },
            onEqualizer: { model.setEqualizer($0, for: id) }
        ).equatable()
    }

    private func idleSection() -> some View {
        DSSection("Молчат сейчас", trailing: "\(model.idleApps.count)") {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.idleApps) { app in row(app) }
            }
        }
        .help("Настрой заранее: громкость запомнится и применится, когда приложение начнёт звучать")
    }

    private func presetSection() -> some View {
        DSSection("Настроены заранее", trailing: "\(model.presetApps.count)") {
            ForEach(model.presetApps) { app in
                let id = app.id
                PresetRow(app: app, onReset: { model.reset(id) }).equatable()
            }
        }
    }

    private func othersSection() -> some View {
        DSSection("Остальные запущенные") {
            // Кликается вся строка, а не только стрелка.
            Button {
                showOthers.toggle()
            } label: {
                OthersToggle(expanded: showOthers, count: model.otherApps.count)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Звука от них обычно нет. Зазвучат — переедут наверх")
            if showOthers {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.otherApps) { app in row(app) }
                }
            }
        }
    }

    var body: some View {
        DSPage(
            module: .mixer,
            subtitle: model.apps.isEmpty ? "Сейчас ничего не играет" : "Играют: \(model.apps.count)"
        ) {
            if model.permissionProblem {
                DSSection("Нужно разрешение") {
                    DSRow(icon: "lock.shield", title: "Запись системного звука",
                          subtitle: model.runsInUtility
                              ? "Без неё громкость не меняется. Включи Микшер в «Конфиденциальность и безопасность → Запись экрана и системного звука». Если громкость не заработает, выключи модуль и включи снова."
                              : "Без неё громкость не меняется. Включи Utilitumus в «Конфиденциальность и безопасность → Запись экрана и системного звука» и перезапусти приложение.") {
                        DSButton("Открыть настройки…", small: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                if !Kit.standRefuses("системные настройки") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    if let error = model.lastError {
                        DSRow(icon: "exclamationmark.triangle.fill", title: error)
                    }
                }
            }

            // Блоки ближе друг к другу, чем в остальных модулях: список здесь главное.
            VStack(alignment: .leading, spacing: 14) {
                DSSection("Сейчас играют", trailing: model.apps.isEmpty ? nil : "\(model.apps.count)") {
                    if model.apps.isEmpty {
                        Text("Сейчас ничего не играет").font(DS.rowTitle).foregroundStyle(.white.opacity(0.6))
                            .modifier(RowDivider())
                    }
                    ForEach(model.apps) { app in row(app) }
                }

                // Все секции на всю ширину и теми же строками: громкость молчащим ставят заранее.
                if !model.idleApps.isEmpty { idleSection() }
                if !model.presetApps.isEmpty { presetSection() }
                if !model.otherApps.isEmpty { othersSection() }

                Note(model.runsInUtility
                     ? "Выше 100 % громкость не поднять. Микшер работает и без Utilitumus. Выключи модуль или выйди из Микшера, и всё вернётся как было."
                     : "Выше 100 % громкость не поднять. При выходе из Utilitumus всё возвращается как было.")
            }
        }
        .onPageActive { model.setScreenVisible($0) }
    }
}
