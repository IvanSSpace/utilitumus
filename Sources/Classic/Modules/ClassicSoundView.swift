import SwiftUI

/// Цветной значок устройства: белый символ на скруглённой плашке с градиентом,
/// как у значков модулей. Цвет и символ — по типу подключения, а наушники
/// узнаём по названию (по транспорту они неотличимы от колонок).
private struct ClassicDeviceStyle {
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

private struct ClassicSymbolBadge: View {
    let style: ClassicDeviceStyle
    var size: CGFloat = 24
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

/// Строка выбора, как радиокнопка: отметка слева, серая и с подписью, если
/// устройство не подключено, с замком, если выбрать нельзя.
private struct ClassicChoiceRow: View {
    let style: ClassicDeviceStyle
    let title: String
    let note: String?
    let isSelected: Bool
    let isConnected: Bool
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                ClassicSymbolBadge(style: style, dimmed: !isConnected || isLocked)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .lineLimit(1)
                            .foregroundStyle(isConnected && !isLocked ? .primary : .secondary)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }
}

/// Короткое объяснение вверху экрана: что модуль делает на практике.
private struct ClassicExplainerBlock: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClassicSymbolBadge(style: ClassicDeviceStyle(symbol: "arrow.uturn.backward", tint: .green), size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Подключил наушники — macOS сменила микрофон — вернём твой.")
                    .font(.headline)
                Text("Если выбранный микрофон отключён, входом станет микрофон MacBook. Другие устройства сами входом не станут.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

/// Экран модуля «Звук»: основной микрофон и основной выход.
struct ClassicSoundView: View {
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
        return ClassicChoiceRow(
            style: ClassicDeviceStyle(name: device.name, transport: device.transport),
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
        return ClassicChoiceRow(
            style: ClassicDeviceStyle(name: device.name, transport: device.transport),
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

    var body: some View {
        Form {
            Section {
                ClassicExplainerBlock()
            }
            .listRowBackground(Color.green.opacity(0.10))

            Section("Сейчас") {
                HStack(spacing: 10) {
                    ClassicSymbolBadge(style: ClassicDeviceStyle(symbol: "mic.fill",
                                                   tint: monitorState.currentInputIsBluetooth ? .indigo : .blue))
                    Text(monitorState.currentInputName)
                }
                HStack(spacing: 10) {
                    ClassicSymbolBadge(style: ClassicDeviceStyle(symbol: "speaker.wave.2.fill", tint: .blue))
                    Text(monitorState.currentOutputName)
                }
            }

            Section {
                ForEach(physicalInputs, id: \.uid) { inputRow($0) }
            } header: {
                Text("Основной микрофон")
            } footer: {
                Text("Виртуальные устройства (Loopback, Zoom и т.п.) тут не показаны: основными они не бывают, а выбранные тобой вручную Utilitumus не трогает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Блокировать Bluetooth-микрофон", isOn: $lockState.isLocked)
                    .toggleStyle(.switch)
                    .onChange(of: lockState.isLocked) { _, _ in
                        AudioMonitor.shared.enforcePolicy()
                    }
            } footer: {
                Text(lockState.isLocked
                     ? "Bluetooth-микрофон не станет входом."
                     : "Bluetooth-микрофон можно выбрать основным.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(physicalOutputs, id: \.uid) { outputRow($0) }
                ClassicChoiceRow(
                    style: ClassicDeviceStyle(symbol: "gearshape.fill", tint: .gray),
                    title: "Как решит macOS",
                    note: nil,
                    isSelected: outputStore.choice == .system,
                    isConnected: true,
                    isLocked: false
                ) {
                    outputStore.select(.system)
                    AudioMonitor.shared.enforcePolicy()
                }
            } header: {
                Text("Основной выход")
            } footer: {
                Text("Если macOS переключит звук, вернём выбранный выход. Отключён — звук идёт на динамики MacBook. «Как решит macOS» — не вмешиваться.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Звук")
        .navigationSubtitle("Основной микрофон и выход")
    }
}
