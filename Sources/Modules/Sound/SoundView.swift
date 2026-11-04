import SwiftUI

/// Цветной значок устройства: белый символ на скруглённой плашке с градиентом,
/// как у значков модулей. Цвет и символ — по типу подключения, а наушники
/// узнаём по названию (по транспорту они неотличимы от колонок).
private struct DeviceStyle {
    let symbol: String
    let tint: Color

    private static let headphoneWords = ["airpods", "wh-", "wf-", "buds", "headphone", "headset",
                                         "наушник", "beats", "major", "jabra"]

    init(name: String, transport: Transport) {
        let lower = name.lowercased()
        let isHeadphones = Self.headphoneWords.contains { lower.contains($0) }
        switch transport {
        case .builtIn:
            self.init(symbol: isHeadphones ? "headphones" : "laptopcomputer", tint: .blue)
        case .usb:
            self.init(symbol: isHeadphones ? "headphones" : "cable.connector", tint: .orange)
        case .bluetooth:
            self.init(symbol: isHeadphones ? "headphones" : "wave.3.right", tint: .indigo)
        case .airplay:
            self.init(symbol: "airplayaudio", tint: .pink)
        case .display:
            self.init(symbol: "display", tint: .teal)
        case .virtual, .other:
            self.init(symbol: "waveform", tint: .gray)
        }
    }

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }
}

private struct SymbolBadge: View {
    let style: DeviceStyle
    var size: CGFloat = 30
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(style.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.white)
            }
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.45 : 1)
    }
}

/// Строка устройства в карточке: цветной значок слева. Для выбора — отметка справа,
/// серая и с подписью, если устройство не подключено, с замком, если выбрать нельзя.
private struct DeviceRow<Trailing: View>: View {
    let style: DeviceStyle
    let title: String
    var note: String?
    var dimmed = false
    var locked = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(style: style, size: 30, dimmed: dimmed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(DS.rowTitle).lineLimit(1)
                        .foregroundStyle(.white.opacity(dimmed ? 0.5 : 0.95))
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                if let note {
                    Text(note).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 56)
        }
    }
}

/// Строка выбора, как радиокнопка.
private struct ChoiceRow: View {
    let style: DeviceStyle
    let title: String
    let note: String?
    let isSelected: Bool
    let isConnected: Bool
    let isLocked: Bool
    let action: () -> Void
    @Environment(\.dsTint) private var tint

    var body: some View {
        Button(action: action) {
            DeviceRow(style: style, title: title, note: note, dimmed: !isConnected || isLocked, locked: isLocked) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? tint : .white.opacity(0.25))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }
}

/// Экран модуля «Звук»: основной микрофон и основной выход.
struct SoundView: View {
    @ObservedObject var lockState = LockState.shared
    @ObservedObject var monitorState = MonitorState.shared
    @ObservedObject var inputStore = PrimaryInputStore.shared
    @ObservedObject var outputStore = PrimaryOutputStore.shared
    
    /// Реальные микрофоны — то, что физически выбирают как вход.
    private var physicalInputs: [DisplayDevice] {
        monitorState.displayInputs.filter { $0.transport.isPhysical }
    }

    private var physicalOutputs: [DisplayDevice] {
        monitorState.displayOutputs.filter { $0.transport.isPhysical }
    }

    private var builtInInput: DisplayDevice? {
        SoundPolicy.builtIn(in: physicalInputs, marker: SoundPolicy.microphoneMarker)
    }

    private var builtInOutput: DisplayDevice? {
        SoundPolicy.builtIn(in: physicalOutputs, marker: SoundPolicy.speakerMarker)
    }

    private func inputRow(_ device: DisplayDevice) -> some View {
        let isBuiltIn = device.uid == builtInInput?.uid
        let selectedUID = inputStore.primaryUID ?? builtInInput?.uid
        let isBluetoothBlocked = device.transport == .bluetooth && lockState.isLocked
        return ChoiceRow(
            style: DeviceStyle(name: device.name, transport: device.transport),
            title: isBuiltIn ? "Микрофон MacBook" : device.name,
            note: device.isConnected ? nil : "не подключён",
            isSelected: device.uid == selectedUID,
            isConnected: device.isConnected,
            isLocked: isBluetoothBlocked
        ) {
            inputStore.select(isBuiltIn ? nil : device.uid)
            AudioMonitor.shared.enforcePolicy()
        }
    }

    private func outputRow(_ device: DisplayDevice) -> some View {
        let isBuiltIn = device.uid == builtInOutput?.uid
        let isSelected: Bool
        switch outputStore.choice {
        case .builtIn: isSelected = isBuiltIn
        case .device(let uid): isSelected = device.uid == uid
        case .system: isSelected = false
        }
        return ChoiceRow(
            style: DeviceStyle(name: device.name, transport: device.transport),
            title: isBuiltIn ? "Динамики MacBook" : device.name,
            note: device.isConnected ? nil : "не подключён",
            isSelected: isSelected,
            isConnected: device.isConnected,
            isLocked: false
        ) {
            outputStore.select(isBuiltIn ? .builtIn : .device(device.uid))
            AudioMonitor.shared.enforcePolicy()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                DSSection("Основной микрофон") {
                    ForEach(physicalInputs, id: \.uid) { inputRow($0) }
                }
                caption("Виртуальные устройства (Loopback, Zoom и т.п.) тут не показаны: основными они не бывают, а выбранные тобой вручную Utilitumus не трогает.")
            }
            DSSection("Bluetooth") {
                DSRow(icon: "lock.shield", title: "Блокировать Bluetooth-микрофон",
                      subtitle: lockState.isLocked
                          ? "Bluetooth-микрофон не станет входом."
                          : "Bluetooth-микрофон можно выбрать основным.") {
                    DSToggle("Блокировать Bluetooth-микрофон", isOn: $lockState.isLocked)
                }
            }
            .onChange(of: lockState.isLocked) { _, _ in
                AudioMonitor.shared.enforcePolicy()
            }
        }
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Основной выход") {
                ForEach(physicalOutputs, id: \.uid) { outputRow($0) }
                ChoiceRow(
                    style: DeviceStyle(symbol: "gearshape.fill", tint: .gray),
                    title: "Как решит macOS",
                    note: nil,
                    isSelected: outputStore.choice == .system,
                    isConnected: true,
                    isLocked: false
                ) {
                    outputStore.select(.system)
                    AudioMonitor.shared.enforcePolicy()
                }
            }
            caption("Если macOS переключит звук, вернём выбранный выход. Отключён — звук идёт на динамики MacBook. «Как решит macOS» — не вмешиваться.")
        }
    }

    var body: some View {
        DSPage(module: .sound) {
            DSSection("Что делает") {
                DSRow(icon: "arrow.uturn.backward",
                      title: "Подключил наушники — macOS сменила микрофон — вернём твой.",
                      subtitle: "Если выбранный микрофон отключён, входом станет микрофон MacBook. Другие устройства сами входом не станут.")
            }

            DSSection("Сейчас") {
                DeviceRow(style: DeviceStyle(symbol: "mic.fill",
                                             tint: monitorState.currentInputIsBluetooth ? .indigo : .blue),
                          title: monitorState.currentInputName, note: "микрофон") { EmptyView() }
                DeviceRow(style: DeviceStyle(symbol: "speaker.wave.2.fill", tint: .blue),
                          title: monitorState.currentOutputName, note: "выход") { EmptyView() }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    inputColumn.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                    outputColumn.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: DS.blockSpacing) {
                    inputColumn
                    outputColumn
                }
            }
        }
    }
}
