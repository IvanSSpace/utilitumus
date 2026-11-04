import AppKit
import CoreAudio
import Foundation

/// Приложение в списке микшера.
struct MixerApp: Identifiable {
    /// Bundle id приложения (или `exe:<имя>` у программ без бандла) — по нему
    /// запоминается громкость.
    let id: String
    let name: String
    let icon: NSImage
    var volume: Double
    var muted: Bool
}

/// Громкость каждого приложения отдельно. Тап создаётся только для приложений,
/// у которых громкость не 100 % или включено «без звука»: пока микшером не
/// пользуются, звук идёт мимо него. Всё на main thread: опрос списка процессов
/// стоит микросекунды, реалтайм-часть живёт внутри `ProcessTap`.
@MainActor
final class MixerController: ObservableObject {
    static let shared = MixerController()

    /// Сколько приложение остаётся в списке после того, как замолчало: паузы
    /// между треками не должны дёргать строку и пересоздавать тап.
    private static let lingerSeconds: TimeInterval = 3
    /// Тап без единого вызова IOProc за это время считается нерабочим.
    private static let healthSeconds: TimeInterval = 2
    private static let retrySeconds: TimeInterval = 30
    private static let volumesKey = "MixerVolumes"
    private static let mutedKey = "MixerMuted"

    @Published private(set) var apps: [MixerApp] = []
    /// Тап не получил данных или система отказала: почти всегда нет разрешения
    /// «Запись системного звука».
    @Published private(set) var permissionProblem = false
    @Published private(set) var lastError: String?

    private final class Session {
        var name: String
        var icon: NSImage
        var objectIDs: Set<AudioObjectID> = []
        var lastPlaying = Date()
        var tap: ProcessTap?
        var failedAt: Date?
        init(name: String, icon: NSImage) { self.name = name; self.icon = icon }
    }

    private var sessions: [String: Session] = [:]
    private var volumes: [String: Double]
    private var muted: Set<String>
    private var timer: Timer?
    private var unlisten: [() -> Void] = []

    private init() {
        volumes = UserDefaults.standard.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        muted = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
    }

    func start() {
        guard timer == nil else { return }
        // Включение и выключение вывода у уже известного процесса событиями не
        // приходит, поэтому список ещё и опрашивается.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MixerController.shared.refresh() }
        }
        timer?.tolerance = 0.3
        // Новый процесс и смена устройства вывода реагируют сразу, без ожидания опроса.
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            unlisten.append(MixerHAL.listen(selector) {
                Task { @MainActor in MixerController.shared.refresh() }
            })
        }
        refresh()
    }

    func volume(for id: String) -> Double { volumes[id] ?? 1 }

    func setVolume(_ value: Double, for id: String) {
        let clamped = min(max(value, 0), 1)
        if clamped == 1 { volumes[id] = nil } else { volumes[id] = clamped }
        persist()
        sessions[id]?.failedAt = nil
        refresh()
    }

    func setMuted(_ value: Bool, for id: String) {
        if value { muted.insert(id) } else { muted.remove(id) }
        persist()
        sessions[id]?.failedAt = nil
        refresh()
    }

    private func persist() {
        UserDefaults.standard.set(volumes, forKey: Self.volumesKey)
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
    }

    /// Выключение модуля или выход: снести все тапы и агрегаты, чтобы звук
    /// приложений вернулся как был.
    func stop() {
        timer?.invalidate()
        timer = nil
        unlisten.forEach { $0() }
        unlisten = []
        for session in sessions.values {
            session.tap?.destroy()
            session.tap = nil
        }
        sessions = [:]
        apps = []
        permissionProblem = false
        lastError = nil
    }

    // MARK: - Обновление

    private func refresh() {
        // Уже поставленный в очередь вызов после stop() не должен снова создать тапы.
        guard timer != nil else { return }
        let now = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        var groups: [String: (name: String, icon: NSImage, ids: Set<AudioObjectID>, playing: Bool)] = [:]

        for process in MixerHAL.processes() where process.pid != me {
            let owner = MixerHAL.responsiblePID(for: process.pid)
            if owner == me { continue }
            let app = NSRunningApplication(processIdentifier: owner)
            let exe = Self.executableName(of: process.pid)
            let key = app?.bundleIdentifier ?? process.bundleID ?? "exe:\(exe)"
            var group = groups[key] ?? (
                app?.localizedName ?? exe,
                app?.icon ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage(),
                [], false)
            group.ids.insert(process.objectID)
            group.playing = group.playing || process.isRunningOutput
            groups[key] = group
        }

        for (key, group) in groups {
            // В список попадают только те, кто играет (или играл только что).
            guard group.playing || sessions[key] != nil else { continue }
            let session = sessions[key] ?? Session(name: group.name, icon: group.icon)
            sessions[key] = session
            session.objectIDs = group.ids
            if group.playing { session.lastPlaying = now }
        }

        // Процесс закрылся или давно молчит: строку и тап убираем, звук возвращается.
        for (key, session) in sessions where groups[key] == nil || now.timeIntervalSince(session.lastPlaying) > Self.lingerSeconds {
            session.tap?.destroy()
            sessions[key] = nil
        }

        let outputUID = MixerHAL.defaultOutputUID()
        for (key, session) in sessions { apply(key, session, outputUID: outputUID, now: now) }
        clearPermissionProblemIfWorking()

        let list = sessions.map { key, session in
            MixerApp(id: key, name: session.name, icon: session.icon,
                     volume: volume(for: key), muted: muted.contains(key))
        }.sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
        // Публикуем только изменения, иначе SwiftUI перерисовывает экран раз в секунду зря.
        if list.map({ [$0.id, "\($0.volume)", "\($0.muted)"] }) != apps.map({ [$0.id, "\($0.volume)", "\($0.muted)"] }) {
            apps = list
        }
    }

    private func apply(_ key: String, _ session: Session, outputUID: String?, now: Date) {
        let wantsTap = volume(for: key) != 1 || muted.contains(key)
        let gain = muted.contains(key) ? 0 : Float(volume(for: key))

        // Тап прибит к набору процессов и к устройству вывода: изменились — пересобираем.
        if let tap = session.tap,
           !wantsTap || tap.processObjectIDs != session.objectIDs || tap.outputUID != outputUID {
            tap.destroy()
            session.tap = nil
        }

        if let tap = session.tap {
            // Тап без данных держит приложение заглушенным — снимаем, пока не поздно.
            if tap.callbackCount == 0, now.timeIntervalSince(tap.createdAt) > Self.healthSeconds {
                tap.destroy()
                session.tap = nil
                session.failedAt = now
                permissionProblem = true
                lastError = "Тап не получает звук"
            } else {
                tap.setGain(gain)
            }
            return
        }

        guard wantsTap, let outputUID, !session.objectIDs.isEmpty else { return }
        if let failedAt = session.failedAt, now.timeIntervalSince(failedAt) < Self.retrySeconds { return }
        do {
            session.tap = try ProcessTap(processObjectIDs: session.objectIDs, outputUID: outputUID, gain: gain)
            session.failedAt = nil
        } catch {
            session.failedAt = now
            lastError = error.localizedDescription
            if (error as? ProcessTapError)?.isPermissionDenied == true { permissionProblem = true }
        }
    }

    /// Все живые тапы работают — разрешение точно есть, предупреждение снимаем.
    private func clearPermissionProblemIfWorking() {
        if permissionProblem, sessions.values.contains(where: { ($0.tap?.callbackCount ?? 0) > 0 }) {
            permissionProblem = false
            lastError = nil
        }
    }

    private static func executableName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }
}
