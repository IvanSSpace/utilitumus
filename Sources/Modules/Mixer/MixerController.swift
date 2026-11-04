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

    /// Играют сейчас (или играли только что).
    @Published private(set) var apps: [MixerApp] = []
    /// Запущены, но молчат. Тапа у них нет: громкость только запоминается и
    /// применится в `apply`, когда приложение появится в `sessions`.
    @Published private(set) var idleApps: [MixerApp] = []
    /// Громкость или «без звука» заданы, а приложение не запущено.
    @Published private(set) var presetApps: [MixerApp] = []
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
    /// Имя и иконка незапущенных приложений: ищутся по bundle id один раз.
    private var presetMeta: [String: (name: String, icon: NSImage)] = [:]
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

    /// Вернуть приложению 100 % и звук (кнопка в «Настроены заранее»).
    func reset(_ id: String) {
        volumes[id] = nil
        muted.remove(id)
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
        idleApps = []
        presetApps = []
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
        }.sorted(by: Self.byName)
        // Публикуем только изменения, иначе SwiftUI перерисовывает экран раз в секунду зря.
        if Self.signature(list) != Self.signature(apps) { apps = list }

        let (idle, preset) = quietApps(excluding: Set(sessions.keys), me: me)
        if Self.signature(idle) != Self.signature(idleApps) { idleApps = idle }
        if Self.signature(preset) != Self.signature(presetApps) { presetApps = preset }
    }

    private static func byName(_ a: MixerApp, _ b: MixerApp) -> Bool {
        (a.name.localizedLowercase, a.id) < (b.name.localizedLowercase, b.id)
    }

    private static func signature(_ list: [MixerApp]) -> [[String]] {
        list.map { [$0.id, "\($0.volume)", "\($0.muted)"] }
    }

    /// Молчащие приложения: запущенные обычные (idle) и те, для кого что-то
    /// настроено, а среди запущенных обычных их нет (preset). Тапы им не нужны:
    /// громкость лежит в `volumes`, и `apply` возьмёт её, когда появится звук.
    private func quietApps(excluding active: Set<String>, me: pid_t) -> (idle: [MixerApp], preset: [MixerApp]) {
        var idle: [MixerApp] = []
        var running: Set<String> = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            guard let id = app.bundleIdentifier else { continue }
            running.insert(id)
            guard !active.contains(id), !idle.contains(where: { $0.id == id }) else { continue }
            idle.append(MixerApp(id: id, name: app.localizedName ?? id,
                                 icon: app.icon ?? Self.genericIcon,
                                 volume: volume(for: id), muted: muted.contains(id)))
        }

        let configured = Set(volumes.keys).union(muted)
        let preset = configured.subtracting(active).subtracting(running).map { id in
            let meta = presetMeta[id] ?? Self.lookupMeta(id)
            presetMeta[id] = meta
            return MixerApp(id: id, name: meta.name, icon: meta.icon,
                            volume: volume(for: id), muted: muted.contains(id))
        }
        return (idle.sorted(by: Self.byName), preset.sorted(by: Self.byName))
    }

    private static var genericIcon: NSImage {
        NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
    }

    private static func lookupMeta(_ id: String) -> (name: String, icon: NSImage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (id.hasPrefix("exe:") ? String(id.dropFirst(4)) : id, genericIcon)
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
