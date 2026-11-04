import Foundation

/// Известное устройство: имя и тип запоминаются на момент последнего наблюдения,
/// чтобы можно было показать устройство в UI и когда оно физически не подключено
/// (id в CoreAudio у отключённого устройства попросту не существует).
struct KnownDevice: Codable {
    let uid: String
    var name: String
    var transport: Transport
}

/// Устройство для отображения в UI: может быть сейчас не подключено.
struct DisplayDevice: SoundDevice, Equatable {
    let uid: String
    let name: String
    let transport: Transport
    let isConnected: Bool
}

/// Когда-либо виденные устройства, ключуются по persistent device UID (не по
/// AudioDeviceID — тот меняется при каждом переподключении). Порядок записей
/// у входов — старый приоритет, из него переносится основной микрофон.
/// Все методы дёргать только с main thread.
final class KnownDeviceStore {
    static let inputs = KnownDeviceStore(key: "MicGuardKnownDevicesOrder")
    static let outputs = KnownDeviceStore(key: "UtilitumusKnownOutputDevices")

    private let key: String
    private(set) var known: [KnownDevice]

    private init(key: String) {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            known = Self.deduplicated(decoded)
            if known.map(\.uid) != decoded.map(\.uid) { persist() }
        } else {
            known = []
        }
    }

    /// Списки, сохранённые до DeviceIdentity: один USB-микрофон лежит там по
    /// записи на каждый порт, плюс мусорные `id-…`. Оставляем верхнюю по рангу
    /// запись каждого устройства.
    private static func deduplicated(_ list: [KnownDevice]) -> [KnownDevice] {
        var seen = Set<String>()
        return list.compactMap { device in
            let key = DeviceIdentity.stableKey(device.uid)
            guard !DeviceIdentity.isVolatile(key), seen.insert(key).inserted else { return nil }
            return KnownDevice(uid: key, name: device.name, transport: device.transport)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Обновляет имя/тип уже известных устройств (могли переименоваться) и дописывает новые.
    func sync(from devices: [AudioDeviceInfo]) {
        var changed = false
        // Два одинаковых устройства одной модели дают один ключ — берём первое.
        let byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })

        for i in known.indices {
            guard let live = byUID[known[i].uid] else { continue }
            if known[i].name != live.name || known[i].transport != live.transport {
                known[i].name = live.name
                known[i].transport = live.transport
                changed = true
            }
        }

        var knownUIDs = Set(known.map(\.uid))
        for device in devices where knownUIDs.insert(device.uid).inserted {
            known.append(KnownDevice(uid: device.uid, name: device.name, transport: device.transport))
            changed = true
        }

        if changed { persist() }
    }

    /// Полный список для UI: и подключённые сейчас, и когда-то виденные, но сейчас
    /// отсутствующие. Встроенные — первыми, остальные в порядке появления.
    func displayList(available: [AudioDeviceInfo]) -> [DisplayDevice] {
        let availableByUID = Dictionary(available.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let list = known.map { device in
            let live = availableByUID[device.uid]
            return DisplayDevice(
                uid: device.uid,
                name: live?.name ?? device.name,
                transport: live?.transport ?? device.transport,
                isConnected: live != nil
            )
        }
        return list.filter { $0.transport == .builtIn } + list.filter { $0.transport != .builtIn }
    }
}
