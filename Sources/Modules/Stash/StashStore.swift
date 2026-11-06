import Foundation
import AppKit
import ApplicationServices
import CryptoKit

/// Окно программы в стеше: кадр в глобальных координатах экрана (AX, начало сверху слева).
struct StashedWindow: Codable, Equatable {
    /// Хэш заголовка: заголовок нужен только для сопоставления окон, а темы писем и названия документов
    /// незачем держать открытым текстом. В записях старых версий здесь сам заголовок.
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Что сохранять вместо заголовка. Пустой заголовок остаётся пустым: по нему окна не сопоставляются.
    static func storedTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        return SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(title current: String?) -> Bool {
        guard !title.isEmpty, let current, !current.isEmpty else { return false }
        return title == current || title == Self.storedTitle(current)
    }
}

/// Запись стеша: чем была программа и где стояли её окна.
/// Хранится в UserDefaults и переживает обновления приложения. Формат менять
/// только совместимо: новые поля — опциональные, старые не переименовывать,
/// иначе стеш, сделанный до обновления, не вернётся.
struct StashedApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var path: String
    var name: String
    var windows: [StashedWindow]
    var id: String { bundleID }
}

/// Запущенная программа в списке «что закрывать».
struct RunningEntry: Identifiable {
    let app: NSRunningApplication
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }
}

/// Сколько программа ест вместе со всеми своими процессами (у Chrome их десятки).
struct AppUsage: Equatable {
    let memoryMB: Double
    let cpu: Double
    /// Порог «тяжёлой»: от 1 ГБ памяти или от четверти ядра процессора.
    var isHeavy: Bool { memoryMB >= 1024 || cpu >= 25 }
}

/// Сценарий: именованный набор программ, который прячется одним нажатием.
/// Хранится в UserDefaults; формат менять только совместимо (новые поля — опциональные).
struct StashScenario: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var bundleIDs: [String]
}

/// Итог возврата — показывается на экране, чтобы пропавшее с диска не терялось молча.
struct RestoreReport {
    var restored = 0
    var windowsPlaced = 0
    var missing: [String] = []
    var failed: [String] = []
    var hadAccess = true
}

/// Работа с окнами через Accessibility API. Нужен доступ «Универсальный доступ»,
/// без него всё возвращает пусто и стеш работает без кадров окон.
private enum AXWindows {
    static func standardWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        // Только обычные окна: панели, диалоги и меню возвращать на место незачем.
        return list.filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func frame(of window: AXUIElement) -> StashedWindow? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return StashedWindow(title: StashedWindow.storedTitle(string(window, kAXTitleAttribute)),
                             x: point.x, y: point.y, width: size.width, height: size.height)
    }

    static func capture(pid: pid_t) -> [StashedWindow] {
        standardWindows(pid: pid).compactMap(frame(of:))
    }

    @discardableResult
    static func apply(_ saved: StashedWindow, to window: AXUIElement) -> Bool {
        var point = CGPoint(x: saved.x, y: saved.y)
        var size = CGSize(width: saved.width, height: saved.height)
        guard let pos = AXValueCreate(.cgPoint, &point), let sz = AXValueCreate(.cgSize, &size) else { return false }
        // Позиция, размер и снова позиция: при смене размера система может сдвинуть окно.
        let a = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        let b = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        let c = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        return a == .success && (b == .success || c == .success)
    }

    /// Сначала по заголовку (каждое окно один раз), оставшиеся — по порядку.
    static func match(saved: [StashedWindow], to windows: [AXUIElement]) -> [(StashedWindow, AXUIElement)] {
        var free = Array(windows.enumerated())
        var pairs: [(StashedWindow, AXUIElement)] = []
        var unmatched: [StashedWindow] = []
        for s in saved {
            if let i = free.firstIndex(where: { s.matches(title: string($0.element, kAXTitleAttribute)) }) {
                pairs.append((s, free.remove(at: i).element))
            } else {
                unmatched.append(s)
            }
        }
        for (s, w) in zip(unmatched, free) { pairs.append((s, w.element)) }
        return pairs
    }
}

/// Стеш программ: закрыть отмеченные штатно, запомнить их и окна, потом вернуть.
/// Запись лежит в UserDefaults и переживает перезапуск и перезагрузку.
@MainActor
final class StashStore: ObservableObject {
    static let shared = StashStore()

    /// Сколько ждём штатного закрытия и появления окон после запуска.
    static let waitSeconds = 10.0

    private static let stashKey = "StashedApps"
    private static let excludedKey = "StashExcludedBundleIDs"
    private static let scenariosKey = "StashScenarios"
    /// Finder и сам Utilitumus не показываем и не закрываем никогда.
    private static let protectedIDs: Set<String> = ["com.apple.finder"]

    @Published private(set) var running: [RunningEntry] = []
    /// Память и процессор по bundle id — обновляется, пока экран открыт.
    @Published private(set) var usage: [String: AppUsage] = [:]
    /// «Не закрывать». Храним исключённых, чтобы новая программа по умолчанию была отмечена.
    @Published private(set) var excluded: Set<String>
    @Published private(set) var stashed: [StashedApp]
    @Published private(set) var scenarios: [StashScenario]
    /// Не закрылись за `waitSeconds` — ждут решения пользователя.
    @Published private(set) var stubborn: [RunningEntry] = []
    @Published private(set) var busy: String?
    @Published private(set) var report: RestoreReport?
    @Published private(set) var axTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    /// Значки по bundle id и по пути. Не @Published: чтение из body не должно
    /// ходить в NSWorkspace каждый раз, а запись в кэш не должна перерисовывать экран.
    private var iconByBundleID: [String: NSImage] = [:]
    private var iconByPath: [String: NSImage] = [:]
    private var missingBundleIDs: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excluded = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
        scenarios = defaults.data(forKey: Self.scenariosKey)
            .flatMap { try? JSONDecoder().decode([StashScenario].self, from: $0) } ?? []
        let data = defaults.data(forKey: Self.stashKey)
        if let data, let decoded = try? JSONDecoder().decode([StashedApp].self, from: data) {
            stashed = decoded
        } else {
            stashed = []
            // Запись не читается (формат сменился в новой версии) — не выбрасываем
            // её: следующий save() затёр бы стеш навсегда. Откладываем под отдельный
            // ключ, чтобы можно было восстановить вручную или миграцией.
            if let data {
                defaults.set(data, forKey: Self.stashKey + ".unreadable")
                defaults.removeObject(forKey: Self.stashKey)
            }
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let gone = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                    .flatMap { name == NSWorkspace.didTerminateApplicationNotification ? $0.processIdentifier : nil }
                MainActor.assumeIsolated { self?.refresh(excluding: gone) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        })
        refresh()
    }

    /// Выключение модуля: снять подписки на запуск и выход программ. Запись
    /// стеша не трогаем — она нужна, чтобы вернуть программы после включения.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach {
            center.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
    }

    // MARK: Список программ

    static func isEligible(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated,
              let id = app.bundleIdentifier else { return false }
        return isEligible(bundleID: id)
    }

    /// Лаунчер, утилиты и помощники не закрываем: из утилиты свой id уже не защитил бы лаунчер.
    static func isEligible(bundleID id: String) -> Bool {
        !protectedIDs.contains(id) && !Kit.isOurs(id)
    }

    private static func entry(_ app: NSRunningApplication) -> RunningEntry? {
        guard isEligible(app), let id = app.bundleIdentifier else { return nil }
        return RunningEntry(app: app, bundleID: id, name: app.localizedName ?? id, icon: app.icon)
    }

    /// `excluding` — программа, о завершении которой только что сообщили: в списке
    /// `runningApplications` она может задержаться ещё на тик.
    func refresh(excluding gonePID: pid_t? = nil) {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != gonePID }
            .compactMap(Self.entry)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        stubborn = stubborn.filter { !$0.app.isTerminated && $0.app.processIdentifier != gonePID }
        refreshAccess()
    }

    func refreshAccess() {
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
    }

    func isClosing(_ bundleID: String) -> Bool { !excluded.contains(bundleID) }

    /// Самые тяжёлые сверху; пока замеров нет — по имени.
    var runningByWeight: [RunningEntry] {
        running.sorted { (usage[$0.bundleID]?.memoryMB ?? 0) > (usage[$1.bundleID]?.memoryMB ?? 0) }
    }

    /// Отметить к закрытию только тяжёлые, остальные — не закрывать.
    func selectOnlyHeavy() {
        for entry in running { setClosing(entry.bundleID, usage[entry.bundleID]?.isHeavy ?? false) }
    }

    /// Память и процессор каждой программы: все процессы, чей исполняемый файл
    /// лежит внутри её .app (хелперы Chrome, рендереры и т. п.), суммируются.
    /// Через `ps`, а не libproc: одна команда на все процессы, без прав.
    func refreshUsage() async {
        // Окно скрыто или свёрнуто — запускать ps незачем.
        guard Self.windowIsVisible() else { return }
        let bundles: [String: String] = running.reduce(into: [:]) { acc, entry in
            if let url = entry.app.bundleURL { acc[url.path + "/"] = entry.bundleID }
        }
        let result = await Task.detached { () -> [String: AppUsage] in
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "rss=,pcpu=,comm="]
            let out = Pipe()
            ps.standardOutput = out
            guard (try? ps.run()) != nil else { return [:] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            var memoryKB: [String: Double] = [:], cpu: [String: Double] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let rss = Double(parts[0]), let pc = Double(parts[1]) else { continue }
                let path = String(parts[2])
                guard let id = Self.bundleID(forExecutable: path, in: bundles) else { continue }
                memoryKB[id, default: 0] += rss
                cpu[id, default: 0] += pc
            }
            // Округляем до МБ и процента: иначе каждый замер отличается в дробной части
            // и экран перерисовывается зря.
            return memoryKB.reduce(into: [:]) { acc, item in
                acc[item.key] = AppUsage(memoryMB: (item.value / 1024).rounded(), cpu: (cpu[item.key] ?? 0).rounded())
            }
        }.value
        if result != usage { usage = result }
    }

    /// Программа, внутри чьего .app лежит исполняемый файл: ищем префиксы по границам
    /// «.app/», внешний первым (хелперы вложены в .app основной программы).
    nonisolated private static func bundleID(forExecutable path: String, in bundles: [String: String]) -> String? {
        var searchStart = path.startIndex
        while let range = path.range(of: ".app/", range: searchStart..<path.endIndex) {
            if let id = bundles[String(path[..<range.upperBound])] { return id }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Окно скрыто или свёрнуто — замерять нечего.
    private static func windowIsVisible() -> Bool {
        guard NSApp != nil else { return true }
        return NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    func setClosing(_ bundleID: String, _ closing: Bool) {
        if closing { excluded.remove(bundleID) } else { excluded.insert(bundleID) }
        defaults.set(Array(excluded).sorted(), forKey: Self.excludedKey)
    }

    /// Отмеченные запущенные программы — то, что закроет «Спрятать выбранное».
    var selected: [NSRunningApplication] {
        running.filter { isClosing($0.bundleID) }.map(\.app)
    }

    // MARK: Сценарии

    private func saveScenarios() {
        if scenarios.isEmpty {
            defaults.removeObject(forKey: Self.scenariosKey)
        } else if let data = try? JSONEncoder().encode(scenarios) {
            defaults.set(data, forKey: Self.scenariosKey)
        }
    }

    private var selectedBundleIDs: [String] {
        running.filter { isClosing($0.bundleID) }.map(\.bundleID)
    }

    @discardableResult
    func addScenario(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedBundleIDs.isEmpty else { return false }
        scenarios.append(StashScenario(id: UUID(), name: name, bundleIDs: selectedBundleIDs))
        saveScenarios()
        return true
    }

    func updateScenario(_ id: UUID) {
        guard !selectedBundleIDs.isEmpty, let i = scenarios.firstIndex(where: { $0.id == id }) else { return }
        scenarios[i].bundleIDs = selectedBundleIDs
        saveScenarios()
    }

    func renameScenario(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = scenarios.firstIndex(where: { $0.id == id }) else { return }
        scenarios[i].name = name
        saveScenarios()
    }

    func deleteScenario(_ id: UUID) {
        scenarios.removeAll { $0.id == id }
        saveScenarios()
    }

    /// Запущенные сейчас программы сценария.
    func runningApps(of scenario: StashScenario) -> [RunningEntry] {
        running.filter { scenario.bundleIDs.contains($0.bundleID) }
    }

    /// Поставить тумблеры: закрывать только программы сценария.
    func select(_ scenario: StashScenario) {
        for entry in running { setClosing(entry.bundleID, scenario.bundleIDs.contains(entry.bundleID)) }
    }

    func stash(_ scenario: StashScenario) async {
        await stash(runningApps(of: scenario).map(\.app))
    }

    /// Значок программы, даже если она не запущена: по bundle id из сценария.
    func icon(forBundleID id: String) -> NSImage? {
        if let cached = iconByBundleID[id] { return cached }
        if let icon = running.first(where: { $0.bundleID == id })?.icon {
            iconByBundleID[id] = icon
            return icon
        }
        guard !missingBundleIDs.contains(id) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            missingBundleIDs.insert(id)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconByBundleID[id] = icon
        return icon
    }

    /// Значок по пути к .app (для плашек «Вернуть»): один запрос к NSWorkspace на путь.
    func icon(forPath path: String) -> NSImage {
        if let cached = iconByPath[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconByPath[path] = icon
        return icon
    }

    // MARK: Доступ

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Стеш

    private func save() {
        if stashed.isEmpty {
            defaults.removeObject(forKey: Self.stashKey)
        } else if let data = try? JSONEncoder().encode(stashed) {
            defaults.set(data, forKey: Self.stashKey)
        }
    }

    /// Запомнить переданные программы и закрыть их штатно. Список явный, чтобы
    /// тест мог передать только свои программы. Finder и Utilitumus отсеиваются здесь же.
    func stash(_ apps: [NSRunningApplication]) async {
        guard busy == nil else { return }
        let targets = apps.filter(Self.isEligible)
        guard !targets.isEmpty else { return }
        busy = "Закрываю программы…"
        report = nil
        defer { busy = nil }

        let trusted = AXIsProcessTrusted()
        var records: [StashedApp] = []
        for app in targets {
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { continue }
            records.append(StashedApp(bundleID: id, path: url.path, name: app.localizedName ?? id,
                                      windows: trusted ? AXWindows.capture(pid: app.processIdentifier) : []))
        }
        // Новая запись заменяет старую той же программы, остальное остаётся.
        let ids = Set(records.map(\.bundleID))
        stashed = stashed.filter { !ids.contains($0.bundleID) } + records
        save()

        for app in targets { app.terminate() }

        let deadline = Date().addingTimeInterval(Self.waitSeconds)
        while Date() < deadline, targets.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        stubborn = targets.filter { !$0.isTerminated }.compactMap(Self.entry)
        refresh()
    }

    func stashSelected() async { await stash(selected) }

    /// Принудительное закрытие — только по явной просьбе, только для тех, что не закрылись сами.
    func forceTerminate(_ entry: RunningEntry) {
        guard Self.isEligible(entry.app) else { return }
        entry.app.forceTerminate()
        stubborn.removeAll { $0.bundleID == entry.bundleID }
        refresh()
    }

    func forceTerminateAll() {
        for entry in stubborn { forceTerminate(entry) }
    }

    // MARK: Возврат

    /// Открыть программы из стеша без вывода вперёд и вернуть окна на места.
    func restore() async {
        guard busy == nil, !stashed.isEmpty else { return }
        busy = "Возвращаю программы…"
        defer { busy = nil }

        let trusted = AXIsProcessTrusted()
        var result = RestoreReport(hadAccess: trusted)
        var launched: [(StashedApp, NSRunningApplication)] = []

        for record in stashed {
            let url = URL(fileURLWithPath: record.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.missing.append(record.name)
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            // Не красть фокус: вернуть надо всё, а не выбрать одну программу.
            config.activates = false
            do {
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                result.restored += 1
                launched.append((record, app))
            } catch {
                result.failed.append(record.name)
            }
        }

        if trusted {
            // Окна у только что запущенных программ появляются не сразу: опрашиваем
            // все разом до общего срока.
            var pending = launched.filter { !$0.0.windows.isEmpty }
            let deadline = Date().addingTimeInterval(Self.waitSeconds)
            while !pending.isEmpty {
                let last = Date() >= deadline
                pending = pending.filter { record, app in
                    let windows = AXWindows.standardWindows(pid: app.processIdentifier)
                    guard windows.count >= record.windows.count || (last && !windows.isEmpty) else { return true }
                    for (saved, window) in AXWindows.match(saved: record.windows, to: windows) {
                        if AXWindows.apply(saved, to: window) { result.windowsPlaced += 1 }
                    }
                    return false
                }
                if last { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        stashed = []
        save()
        report = result
        refresh()
    }
}
