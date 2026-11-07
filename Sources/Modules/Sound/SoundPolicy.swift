import Foundation
import CoreAudio

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: Transport
}

extension AudioDeviceInfo: SoundDevice {}

/// Время, когда набор откатов считается «борьбой» с системой.
/// macOS ставит Bluetooth-гарнитуру ВРЕМЕННЫМ default input на время звонка
/// (Telegram/FaceTime) и сама откатывает после. Откат на каждый такой скачок
/// превращается в борьбу за Bluetooth-профиль (HFP/A2DP), которая рвёт и вход,
/// и выход (общий радиоканал). Если откатов слишком много за короткое время —
/// это не случайный захват, а борьба, и мы отступаем на паузу.
struct CorrectionThrottle {
    private var recent: [Date] = []
    private var backoffUntil: Date?

    /// true — откат разрешён и засчитан; false — пауза или только что ушли в неё.
    mutating func allow(at now: Date) -> Bool {
        if let backoffUntil, now < backoffUntil { return false }
        recent.append(now)
        recent.removeAll { now.timeIntervalSince($0) > 5 }
        guard recent.count < 3 else {
            backoffUntil = now.addingTimeInterval(25)
            recent.removeAll()
            return false
        }
        return true
    }
}

/// Чистые решения без обращений к CoreAudio и UserDefaults: список устройств
/// и настройки на входе, на выходе — что поставить или nil («не трогать»).
enum SoundPolicy {
    static let microphoneMarker = SoundShared.microphoneMarker
    static let speakerMarker = SoundShared.speakerMarker

    static func builtIn<D: SoundDevice>(in devices: [D], marker: String) -> D? {
        SoundShared.builtIn(in: devices, marker: marker)
    }

    /// Вход: основной, если он подключён и не заблокирован; иначе микрофон MacBook.
    /// Никакой другой микрофон сам выбраться не может. Если текущий вход виртуальный —
    /// его выбрали руками ради роутинга, не вмешиваемся.
    static func desiredInput(devices: [AudioDeviceInfo],
                             currentID: AudioDeviceID?,
                             primaryUID: String?,
                             bluetoothLocked: Bool) -> AudioDeviceInfo? {
        if let currentID, let current = devices.first(where: { $0.id == currentID }),
           !current.transport.isPhysical { return nil }

        let physical = devices.filter { $0.transport.isPhysical }
        let target: AudioDeviceInfo?
        if let primaryUID,
           let primary = physical.first(where: { $0.uid == primaryUID }),
           !(primary.transport == .bluetooth && bluetoothLocked) {
            target = primary
        } else {
            target = builtIn(in: physical, marker: microphoneMarker)
        }
        guard let target, target.id != currentID else { return nil }
        return target
    }

    /// Выход: выбранный, если подключён; иначе встроенные динамики.
    /// Не перебиваем: «Как решит macOS», виртуальный выход (выбран руками),
    /// Bluetooth и AirPlay (человек включил AirPods в системе — иначе они бесполезны).
    static func desiredOutput(devices: [AudioDeviceInfo],
                              currentID: AudioDeviceID?,
                              choice: OutputChoice) -> AudioDeviceInfo? {
        if choice == .system { return nil }
        if let currentID, let current = devices.first(where: { $0.id == currentID }),
           !current.transport.isPhysical
            || current.transport == .bluetooth
            || current.transport == .airplay { return nil }

        let physical = devices.filter { $0.transport.isPhysical }
        let target: AudioDeviceInfo?
        if case .device(let uid) = choice, let chosen = physical.first(where: { $0.uid == uid }) {
            target = chosen
        } else {
            target = builtIn(in: physical, marker: speakerMarker)
        }
        guard let target, target.id != currentID else { return nil }
        return target
    }

    /// Перенос со старого приоритета: основным становится верхнее по порядку
    /// подключённое физическое устройство, если оно включено галочкой (и не
    /// заблокированный Bluetooth); иначе nil — встроенный микрофон.
    static func migratedPrimaryInput(oldOrder: [String],
                                     connected: [AudioDeviceInfo],
                                     disabled: Set<String>,
                                     bluetoothLocked: Bool) -> String? {
        let physical = connected.filter { $0.transport.isPhysical }
        for uid in oldOrder {
            guard let device = physical.first(where: { $0.uid == uid }) else { continue }
            if disabled.contains(uid) { return nil }
            if device.transport == .bluetooth && bluetoothLocked { return nil }
            if device.transport == .builtIn { return nil }
            return uid
        }
        return nil
    }
}
