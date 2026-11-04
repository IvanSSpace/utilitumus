import AppKit
import CoreAudio
import Foundation

/// Приложение в списке микшера.
struct MixerApp: Identifiable, Equatable {
    /// Bundle id приложения (или `exe:<имя>` у программ без бандла) — по нему
    /// запоминается громкость.
    let id: String
    let name: String
    let icon: NSImage
    var volume: Double
    var muted: Bool

    /// Иконка в сравнение не входит: она не меняется, а сравнивать картинки дорого.
    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.name == b.name && a.volume == b.volume && a.muted == b.muted
    }
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
    /// Запущены и молчат, но звука от них не ждём (Finder, редакторы): прячутся под «Остальные».
    @Published private(set) var otherApps: [MixerApp] = []
    /// Кто хоть раз звучал: таких показываем в «Молчат сейчас», даже если они не из списка медиа.
    private var heard: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "MixerHeard") ?? [])
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
    /// Экран «Микшер» открыт. Пока нет, молчащие приложения и пресеты не считаются:
    /// в фоне нужны только сессии и тапы.
    private var screenVisible = false
    /// Отложенная запись громкостей в UserDefaults (слайдер шлёт десятки значений в секунду).
    private var persistTask: Task<Void, Never>?

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
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    /// Экран показан или скрыт (`onAppear` / `onDisappear`). При показе сразу
    /// досчитываем списки молчащих.
    func setScreenVisible(_ value: Bool) {
        guard screenVisible != value else { return }
        screenVisible = value
        if value { refresh() }
    }

    /// Шаг слайдера: громкость и gain тапа меняются сразу, без обхода HAL. Полный
    /// `refresh` нужен, только когда тап надо создать или убрать.
    func setVolume(_ value: Double, for id: String) {
        let clamped = min(max(value, 0), 1)
        let before = wantsTap(id)
        if clamped == 1 { volumes[id] = nil } else { volumes[id] = clamped }
        applyChange(id, wantsTapBefore: before)
        schedulePersist()
    }

    func setMuted(_ value: Bool, for id: String) {
        let before = wantsTap(id)
        if value { muted.insert(id) } else { muted.remove(id) }
        applyChange(id, wantsTapBefore: before)
        publishValues()
        persist()
    }

    /// Вернуть приложению 100 % и звук (кнопка в «Настроены заранее»).
    func reset(_ id: String) {
        let before = wantsTap(id)
        volumes[id] = nil
        muted.remove(id)
        applyChange(id, wantsTapBefore: before)
        publishValues()
        persist()
    }

    /// Слайдер отпущен: публикуем итоговые значения и пишем на диск сразу.
    func commitVolumes() {
        publishValues()
        persist()
    }

    private func wantsTap(_ id: String) -> Bool { volume(for: id) != 1 || muted.contains(id) }

    private func applyChange(_ id: String, wantsTapBefore: Bool) {
        let wants = wantsTap(id)
        guard let session = sessions[id] else {
            // Приложения нет в сессиях: тапа нет, громкость применится, когда оно зазвучит.
            // Но строки в «Настроены заранее» и «Молчат» могли поменять состав.
            if wants != wantsTapBefore { refresh() }
            return
        }
        if wants != wantsTapBefore { session.failedAt = nil }
        if let tap = session.tap, wants {
            tap.setGain(muted.contains(id) ? 0 : Float(volume(for: id)))
        } else if (session.tap != nil) != wants, wants != wantsTapBefore || session.failedAt == nil {
            // Тап нужно создать или убрать: это уже работа для полного прохода.
            refresh()
        }
    }

    /// Точечно обновить громкость и «без звука» в уже опубликованных списках,
    /// не пересобирая их.
    private func publishValues() {
        func synced(_ list: [MixerApp]) -> [MixerApp]? {
            var result = list
            var changed = false
            for i in result.indices {
                let v = volume(for: result[i].id), m = muted.contains(result[i].id)
                if result[i].volume != v || result[i].muted != m {
                    result[i].volume = v
                    result[i].muted = m
                    changed = true
                }
            }
            return changed ? result : nil
        }
        if let l = synced(apps) { apps = l }
        if let l = synced(idleApps) { idleApps = l }
        if let l = synced(otherApps) { otherApps = l }
        if let l = synced(presetApps) { presetApps = l }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.publishValues()
            self?.persist()
        }
    }

    private func persist() {
        persistTask?.cancel()
        persistTask = nil
        UserDefaults.standard.set(volumes, forKey: Self.volumesKey)
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
    }

    /// Выключение модуля или выход: снести все тапы и агрегаты, чтобы звук
    /// приложений вернулся как был.
    func stop() {
        if persistTask != nil { persist() }
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
        otherApps = []
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
            if group.playing, !key.hasPrefix("exe:"), heard.insert(key).inserted {
                UserDefaults.standard.set(Array(heard).sorted(), forKey: "MixerHeard")
            }
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
        if list != apps { apps = list }

        // Молчащие и пресеты нужны только открытому экрану.
        guard screenVisible else { return }
        let (quiet, preset) = quietApps(excluding: Set(sessions.keys), me: me)
        let configured = Set(volumes.keys).union(muted)
        let likely = quiet.filter { heard.contains($0.id) || configured.contains($0.id) || Self.isMediaApp($0.id) }
        let likelyIDs = Set(likely.map(\.id))
        let other = quiet.filter { !likelyIDs.contains($0.id) }
        if likely != idleApps { idleApps = likely }
        if other != otherApps { otherApps = other }
        if preset != presetApps { presetApps = preset }
    }

    private static func byName(_ a: MixerApp, _ b: MixerApp) -> Bool {
        (a.name.localizedLowercase, a.id) < (b.name.localizedLowercase, b.id)
    }

    /// Молчащие приложения: запущенные обычные (idle) и те, для кого что-то
    /// настроено, а среди запущенных обычных их нет (preset). Тапы им не нужны:
    /// громкость лежит в `volumes`, и `apply` возьмёт её, когда появится звук.
    private func quietApps(excluding active: Set<String>, me: pid_t) -> (idle: [MixerApp], preset: [MixerApp]) {
        var idle: [MixerApp] = []
        var seen: Set<String> = []
        var running: Set<String> = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            guard let id = app.bundleIdentifier else { continue }
            running.insert(id)
            guard !active.contains(id), seen.insert(id).inserted else { continue }
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

    /// Приложения, от которых обычно ждут звука: браузеры, мессенджеры, созвоны, плееры.
    private static let mediaPrefixes = [
        "com.google.Chrome", "company.thebrowser.", "com.apple.Safari", "org.mozilla.", "com.microsoft.edgemac",
        "com.brave.", "com.operasoftware.", "ru.yandex.", "com.vivaldi.", "org.chromium.",
        "ru.keepcoder.Telegram", "com.tdesktop.", "com.hnc.Discord", "com.tinyspeck.slackmacgap", "us.zoom.",
        "com.microsoft.teams", "com.skype.", "net.whatsapp.", "desktop.WhatsApp", "com.apple.FaceTime",
        "com.spotify.", "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "org.videolan.", "com.colliderli.iina",
        "com.apple.QuickTimePlayerX", "com.apple.iWork.Keynote", "tv.twitch.", "com.valvesoftware.",
    ]

    private static func isMediaApp(_ id: String) -> Bool {
        mediaPrefixes.contains { id.hasPrefix($0) }
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
