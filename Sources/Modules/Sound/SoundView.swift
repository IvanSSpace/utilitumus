import SwiftUI

/// Блёклый акцентный цвет для иконки устройства. Индекс в палитре назначается
/// и хранится в PriorityStore (с избеганием коллизий между одновременно
/// видимыми устройствами) — здесь только сама палитра, порядок должен
/// совпадать с DeviceAccent.paletteSize.
private let deviceAccentPalette: [Color] = [
    Color(red: 0.45, green: 0.58, blue: 0.78), // приглушённый синий
    Color(red: 0.48, green: 0.68, blue: 0.55), // приглушённый зелёный
    Color(red: 0.78, green: 0.48, blue: 0.48), // приглушённый красный
    Color(red: 0.62, green: 0.52, blue: 0.75), // приглушённый фиолетовый
    Color(red: 0.82, green: 0.62, blue: 0.42), // приглушённый оранжевый
    Color(red: 0.42, green: 0.68, blue: 0.68), // приглушённый бирюзовый
    Color(red: 0.78, green: 0.55, blue: 0.65), // приглушённый розовый
    Color(red: 0.72, green: 0.68, blue: 0.42), // приглушённый оливковый
]

private func deviceAccentColor(for device: DisplayDevice) -> Color {
    deviceAccentPalette[device.colorIndex % deviceAccentPalette.count]
}

private struct DeviceRow: View {
    let device: DisplayDevice
    let isLocked: Bool
    /// Только у самого верхнего устройства в приоритете имеет смысл говорить
    /// "подключится — станет входом": для остальных выше по рангу уже что-то
    /// работает, реконнект нижних ничего не поменяет.
    let isTopPriority: Bool
    @ObservedObject var enableStore = DeviceEnableStore.shared

    private var isManuallyDisabled: Bool { enableStore.disabledUIDs.contains(device.uid) }
    private var isBluetoothBlocked: Bool { device.transport == .bluetooth && isLocked }
    private var isBlocked: Bool { isBluetoothBlocked || isManuallyDisabled }

    private var icon: String {
        switch device.transport {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .bluetooth: return "wave.3.right"
        case .virtual, .other: return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !isManuallyDisabled },
                set: { enabled in
                    if enabled {
                        DeviceEnableStore.shared.enable(device.uid)
                    } else {
                        DeviceEnableStore.shared.disable(device.uid)
                    }
                    AudioMonitor.shared.enforcePolicy()
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Circle()
                .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            Image(systemName: icon)
                .foregroundStyle(isBlocked ? .secondary : deviceAccentColor(for: device))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .strikethrough(isBlocked)
                        .foregroundStyle(isBlocked ? .secondary : (device.isConnected ? .primary : .secondary))
                    if isBluetoothBlocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !device.isConnected && isTopPriority {
                    Text(isManuallyDisabled ? "не подключено, выключено" : "не подключено — станет входом при подключении")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                PriorityStore.shared.moveUp(device.uid)
                AudioMonitor.shared.enforcePolicy()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Выше в приоритете")

            Button {
                PriorityStore.shared.moveDown(device.uid)
                AudioMonitor.shared.enforcePolicy()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Ниже в приоритете")
        }
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

/// Экран модуля «Звук» — то, что в MicGuard было выпадающей панелью в строке меню.
struct SoundView: View {
    @ObservedObject var lockState = LockState.shared
    @ObservedObject var monitorState = MonitorState.shared
    @State private var showOtherDevices = false

    /// Реальные микрофоны — то, что физически выбирают как вход.
    private var physicalDevices: [DisplayDevice] {
        monitorState.displayDevices.filter { $0.transport != .virtual && $0.transport != .other }
    }

    /// Виртуальные/неопознанные устройства (Loopback, Screaming Bee, Zoom и т.п.) —
    /// шум от других приложений, а не то, что реально выбирают руками. Сворачиваем.
    private var otherDevices: [DisplayDevice] {
        monitorState.displayDevices.filter { $0.transport == .virtual || $0.transport == .other }
    }

    var body: some View {
        Form {
            Section("Текущий вход") {
                Label {
                    Text(monitorState.currentInputName)
                } icon: {
                    Image(systemName: monitorState.currentInputIsBluetooth ? "wave.3.right.circle.fill" : "waveform.circle.fill")
                }
            }

            Section {
                Toggle("Блокировать Bluetooth-микрофон", isOn: $lockState.isLocked)
                    .toggleStyle(.switch)
                    .onChange(of: lockState.isLocked) { _, _ in
                        AudioMonitor.shared.enforcePolicy()
                    }
            } footer: {
                Text(lockState.isLocked
                     ? "Bluetooth-наушники никогда не станут входом. Приоритет — по списку ниже."
                     : "Bluetooth разрешён как вход по приоритету, пока не включишь блок обратно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(physicalDevices, id: \.uid) { device in
                    DeviceRow(device: device, isLocked: lockState.isLocked, isTopPriority: device.uid == physicalDevices.first?.uid)
                }
            } header: {
                Text("Приоритет входов")
            } footer: {
                Text("Галочка — участвует в выборе. Стрелки — порядок. Неподключённые остаются в списке серыми и вернутся сами.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !otherDevices.isEmpty {
                Section {
                    DisclosureGroup(deviceCountLabel(otherDevices.count), isExpanded: $showOtherDevices) {
                        ForEach(otherDevices, id: \.uid) { device in
                            DeviceRow(device: device, isLocked: lockState.isLocked, isTopPriority: false)
                        }
                    }
                } footer: {
                    Text("Виртуальные устройства (Loopback, Zoom и т.п.). Если такое выбрано входом вручную — Utilitumus его не трогает.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Звук")
        .navigationSubtitle("Приоритет микрофонов")
    }
}
