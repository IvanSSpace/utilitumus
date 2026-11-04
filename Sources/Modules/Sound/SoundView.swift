import SwiftUI

private func icon(for transport: Transport) -> String {
    switch transport {
    case .builtIn: return "laptopcomputer"
    case .usb: return "cable.connector"
    case .bluetooth: return "wave.3.right"
    case .airplay: return "airplayaudio"
    case .display: return "display"
    case .virtual, .other: return "questionmark.circle"
    }
}

/// Строка выбора, как радиокнопка: отметка слева, серая и с подписью, если
/// устройство не подключено, с замком, если выбрать нельзя.
private struct ChoiceRow: View {
    let icon: String
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

                Image(systemName: icon)
                    .foregroundStyle(isConnected && !isLocked ? .primary : .secondary)
                    .frame(width: 18)

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

private func deviceCountLabel(_ n: Int) -> String {
    let mod100 = n % 100
    let mod10 = n % 10
    if (11...14).contains(mod100) { return "Ещё \(n) устройств" }
    switch mod10 {
    case 1: return "Ещё \(n) устройство"
    case 2, 3, 4: return "Ещё \(n) устройства"
    default: return "Ещё \(n) устройств"
    }
}

/// Экран модуля «Звук»: основной микрофон и основной выход.
struct SoundView: View {
    @ObservedObject var lockState = LockState.shared
    @ObservedObject var monitorState = MonitorState.shared
    @ObservedObject var inputStore = PrimaryInputStore.shared
    @ObservedObject var outputStore = PrimaryOutputStore.shared
    @State private var showOtherDevices = false

    /// Реальные микрофоны — то, что физически выбирают как вход.
    private var physicalInputs: [DisplayDevice] {
        monitorState.displayInputs.filter { $0.transport.isPhysical }
    }

    /// Виртуальные/неопознанные устройства (Loopback, Screaming Bee, Zoom и т.п.) —
    /// шум от других приложений, а не то, что реально выбирают руками. Сворачиваем.
    private var otherInputs: [DisplayDevice] {
        monitorState.displayInputs.filter { !$0.transport.isPhysical }
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
            icon: icon(for: device.transport),
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
            icon: icon(for: device.transport),
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
            Section("Сейчас") {
                Label {
                    Text(monitorState.currentInputName)
                } icon: {
                    Image(systemName: monitorState.currentInputIsBluetooth ? "wave.3.right.circle.fill" : "mic.circle.fill")
                }
                Label {
                    Text(monitorState.currentOutputName)
                } icon: {
                    Image(systemName: "speaker.wave.2.circle.fill")
                }
            }

            Section {
                ForEach(physicalInputs, id: \.uid) { inputRow($0) }
            } header: {
                Text("Основной микрофон")
            } footer: {
                Text("Если основной микрофон подключён, он и будет входом. Если нет — микрофон MacBook. Любой другой микрофон, например случайно подключённый провод, сам входом не станет.")
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
                     ? "Bluetooth-наушники не станут входом и не выбираются основным микрофоном."
                     : "Bluetooth-микрофон можно выбрать основным.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !otherInputs.isEmpty {
                Section {
                    DisclosureGroup(deviceCountLabel(otherInputs.count), isExpanded: $showOtherDevices) {
                        ForEach(otherInputs, id: \.uid) { device in
                            Label(device.name, systemImage: icon(for: device.transport))
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Виртуальные устройства (Loopback, Zoom и т.п.) основными не бывают. Если такое выбрано входом вручную, Utilitumus его не трогает.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(physicalOutputs, id: \.uid) { outputRow($0) }
                ChoiceRow(
                    icon: "questionmark.circle",
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
                Text("Если macOS переключит звук на другое устройство, вернём выбранное. Не перебиваем, когда ты сам выбрал в системе Bluetooth-наушники или AirPlay. Если основной выход отключён, звук идёт на динамики MacBook. «Как решит macOS» — не вмешиваться.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Звук")
        .navigationSubtitle("Основной микрофон и выход")
    }
}
