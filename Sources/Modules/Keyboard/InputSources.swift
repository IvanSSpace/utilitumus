import Foundation
import Carbon
import AppKit

/// Тонкая обёртка над Text Input Sources. Все вызовы — с главного потока.
enum InputSources {
    struct Source {
        let id: String
        let name: String
        let ref: TISInputSource
    }

    /// Включённые раскладки в том порядке, в каком их отдаёт система (без сортировки).
    static func enabled() -> [Source] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
              let refs = list as? [TISInputSource] else { return [] }
        return refs.compactMap(source)
    }

    static func current() -> Source? {
        TISCopyCurrentKeyboardInputSource().flatMap { source($0.takeRetainedValue()) }
    }

    static func select(_ source: Source) {
        TISSelectInputSource(source.ref)
    }

    /// Имя уведомления о смене раскладки.
    static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    private static func source(_ ref: TISInputSource) -> Source? {
        guard let id = string(ref, kTISPropertyInputSourceID) else { return nil }
        return Source(id: id, name: string(ref, kTISPropertyLocalizedName) ?? id, ref: ref)
    }

    private static func string(_ ref: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(ref, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

/// Системное действие клавиши 🌐 и диктовка: то, что может сработать вместе с нашим переключением.
enum FnSystemAction {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    /// Прежнее значение, пока мы держим 0: Int, а -1 — ключа не было. Только для отката;
    /// намерение «держать 0» хранит `keepOffKey`, а не наличие этого значения.
    private static let savedKey = "Keyboard.SavedFnUsage"
    /// Пользователь просил отключить системное действие 🌐 и не отменял. Сбрасывается только
    /// выключением модуля пользователем или удалением в Сторе (`restore`).
    private static let keepOffKey = "Keyboard.KeepSystemFnOff"

    /// Текущее значение; nil — ключа нет (система действует по умолчанию, это не «ничего»).
    static var usage: Int? {
        CFPreferencesAppSynchronize(domain)  // значение могли поменять снаружи
        return (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue
    }

    /// Система сама переключит язык или сделает что-то ещё по одному нажатию 🌐.
    static var conflicts: Bool { usage != 0 }

    /// Что делает системное действие, для строки статуса.
    static func title(for usage: Int?) -> String {
        switch usage {
        case 0: return "Ничего не делает"
        case 1: return "Переключает раскладку"
        case 2: return "Показывает эмодзи"
        case 3: return "Запускает диктовку"
        case nil: return "По умолчанию в macOS"
        default: return "Другое действие"
        }
    }

    /// Нужно держать 0, пока модуль включён.
    static var keepsOff: Bool { UserDefaults.standard.bool(forKey: keepOffKey) }

    /// Обновление с версии, где флага не было: модуль включён, система держит 0 (или осталось
    /// запомненное прежнее значение) — значит, пользователь просил отключить. Зовётся при запуске модуля.
    static func migrateKeepOff() {
        let defaults = UserDefaults.standard
        if usage == 0 || defaults.object(forKey: savedKey) != nil { defaults.set(true, forKey: keepOffKey) }
    }

    /// Нужно ли заново отключить действие при запуске модуля: пользователь просил отключить
    /// (`overridden`), а система держит не 0 (после перезапуска приложения, смены настроек).
    static func needsReapply(overridden: Bool, usage: Int?) -> Bool { overridden && usage != 0 }

    /// «Отключить, пока модуль включён»: намерение фиксирует `keepOffKey`.
    static func disable() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: keepOffKey)
        // Прежним считаем то, что стоит сейчас; 0 не затирает уже запомненное.
        if usage != 0 || defaults.object(forKey: savedKey) == nil { defaults.set(usage ?? -1, forKey: savedKey) }
        write(0)
    }

    /// Запуск модуля: вернуть наше «отключено», если приложение перезапускали.
    /// true — значение пришлось вернуть в 0 (его сбросили).
    @discardableResult
    static func reapplyIfNeeded() -> Bool {
        guard needsReapply(overridden: keepsOff, usage: usage) else { return false }
        disable()
        return true
    }

    /// Вернуть значение, если его меняли мы. Зовётся, только когда пользователь выключил модуль
    /// или удалил его в Сторе: при выходе из приложения и обновлении модуль зовёт `quit`.
    static func restore() {
        restoreDictation()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: keepOffKey)
        guard let saved = defaults.object(forKey: savedKey) as? Int else { return }
        write(saved < 0 ? nil : saved)
        defaults.removeObject(forKey: savedKey)
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetAppValue(key, value.map { NSNumber(value: $0) }, domain)
        CFPreferencesAppSynchronize(domain)
        applyToSystem()
    }

    /// macOS не перечитывает AppleFnUsageType сама: TextInputSwitcher держит старое значение и
    /// показывает своё окошко. Просим систему применить настройки и перезапускаем его.
    /// Не на главном потоке; трогаем только процесс текущего пользователя.
    private static func applyToSystem(restartSwitcher: Bool = true) {
        DispatchQueue.global(qos: .utility).async {
            let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
            if FileManager.default.isExecutableFile(atPath: tool) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = ["-u"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit() }
            }
            // SIGTERM он игнорирует, нужен SIGKILL; launchd поднимет его при следующем нажатии.
            if restartSwitcher, let pid = textInputSwitcherPID() { kill(pid, SIGKILL) }
        }
    }

    private static func textInputSwitcherPID() -> pid_t? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputSwitcher")
        if let app = apps.first { return app.processIdentifier }
        // Фоновый агент может не числиться приложением: ищем по имени среди своих процессов.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "-u", String(getuid()), "TextInputSwitcher"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private static let hotKeysDomain = "com.apple.symbolichotkeys" as CFString
    private static let hotKeysKey = "AppleSymbolicHotKeys" as CFString
    /// Диктовка — горячая клавиша 164; запоминаем, что мы её выключили.
    private static let dictationKey = "164"
    private static let savedDictationKey = "Keyboard.SavedDictationEnabled"

    private static var hotKeys: [String: Any]? {
        CFPreferencesAppSynchronize(hotKeysDomain)
        return CFPreferencesCopyAppValue(hotKeysKey, hotKeysDomain) as? [String: Any]
    }

    /// Диктовка по двойному нажатию Fn: горячая клавиша 164 в symbolichotkeys с модификатором Fn.
    static var dictationOnDoubleFn: Bool { isDictationOnDoubleFn(hotKeys) }

    static func isDictationOnDoubleFn(_ all: [String: Any]?) -> Bool {
        guard let item = all?[dictationKey] as? [String: Any],
              (item["enabled"] as? NSNumber)?.boolValue == true,
              let value = item["value"] as? [String: Any],
              value["type"] as? String == "modifier",
              let params = value["parameters"] as? [NSNumber], let mask = params.first else { return false }
        return mask.intValue & 0x800000 != 0
    }

    /// Копия горячих клавиш, где у `id` поле enabled заменено; nil — такой клавиши нет.
    static func settingEnabled(_ all: [String: Any]?, id: String, to enabled: Bool) -> [String: Any]? {
        guard var all, var item = all[id] as? [String: Any] else { return nil }
        item["enabled"] = NSNumber(value: enabled)
        all[id] = item
        return all
    }

    /// Мы сняли диктовку с двойного Fn и помним, что она была включена.
    static var dictationOverridden: Bool { UserDefaults.standard.object(forKey: savedDictationKey) != nil }

    /// Выключить горячую клавишу диктовки; при выключении модуля вернём.
    static func disableDictation() {
        guard isDictationOnDoubleFn(hotKeys), let changed = settingEnabled(hotKeys, id: dictationKey, to: false) else { return }
        UserDefaults.standard.set(true, forKey: savedDictationKey)
        writeHotKeys(changed)
    }

    /// Вернуть диктовку, если выключали мы.
    private static func restoreDictation() {
        guard dictationOverridden else { return }
        UserDefaults.standard.removeObject(forKey: savedDictationKey)
        if let changed = settingEnabled(hotKeys, id: dictationKey, to: true) { writeHotKeys(changed) }
    }

    /// Диктовку сбросили (обновление macOS, правка в настройках), а мы обещали держать выключенной.
    @discardableResult
    static func reapplyDictationIfNeeded() -> Bool {
        guard dictationOverridden, isDictationOnDoubleFn(hotKeys),
              let changed = settingEnabled(hotKeys, id: dictationKey, to: false) else { return false }
        writeHotKeys(changed)
        return true
    }

    private static func writeHotKeys(_ all: [String: Any]) {
        CFPreferencesSetAppValue(hotKeysKey, all as CFDictionary, hotKeysDomain)
        CFPreferencesAppSynchronize(hotKeysDomain)
        applyToSystem(restartSwitcher: false)
    }
}

/// Защищённый ввод (поле пароля, Secure Keyboard Entry): пока он включён, listen-tap не получает
/// клавиатурных событий, и Fn не слышно.
enum SecureInput {
    /// Приложение, держащее защищённый ввод; nil — выключен.
    static func owner() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else {
            return "неизвестном приложении"
        }
        return name
    }
}
