import Foundation
import AppKit

/// Системное действие клавиши 🌐 и диктовка: то, что может сработать вместе с нашим переключением.
enum FnSystemAction {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    /// Прежнее значение, пока мы держим 0: Int, а -1 — ключа не было. Только для отката;
    /// намерение «держать 0» хранит `keepOffKey`, а не наличие этого значения.
    private static let savedKey = "Keyboard.SavedFnUsage"
    /// Пользователь просил отключить системное действие 🌐 и не отменял. Сбрасывается только
    /// выключением модуля, удалением утилиты и передачей без разрешения (`restore`).
    private static let keepOffKey = "Keyboard.KeepSystemFnOff"

    /// Текущее значение; nil — ключа нет (система действует по умолчанию, это не «ничего»).
    static var usage: Int? {
        // Стенд читает не настоящие настройки macOS, а свой ключ в тестовом домене.
        #if KIT_TEST_DEFAULTS
        return Kit.defaults.object(forKey: "Test.FnUsage") as? Int
        #else
        CFPreferencesAppSynchronize(domain)  // значение могли поменять снаружи
        return (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue
        #endif
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
    static var keepsOff: Bool { Kit.defaults.bool(forKey: keepOffKey) }

    /// Обновление с версии, где флага не было: модуль включён, система держит 0 (или осталось
    /// запомненное прежнее значение) — значит, пользователь просил отключить. Зовётся при запуске модуля.
    static func migrateKeepOff() {
        let defaults = Kit.defaults
        if defaults.object(forKey: keepOffKey) == nil { rememberUserZero() }
        if usage == 0 || defaults.object(forKey: savedKey) != nil { defaults.set(true, forKey: keepOffKey) }
    }

    /// Просят держать 0 впервые, а в системе уже 0: он был до нас, откат его оставит. Без этой отметки
    /// «запомненного нет, 0 в системе» нельзя отличить от потерянного значения, которое надо вернуть к умолчанию.
    private static func rememberUserZero() {
        let defaults = Kit.defaults
        if !keepsOff, usage == 0, defaults.object(forKey: savedKey) == nil { defaults.set(0, forKey: savedKey) }
    }

    /// Нужно ли заново отключить действие при запуске модуля: пользователь просил отключить
    /// (`overridden`), а система держит не 0 (после перезапуска приложения, смены настроек).
    static func needsReapply(overridden: Bool, usage: Int?) -> Bool { overridden && usage != 0 }

    /// «Отключить, пока модуль включён»: намерение фиксирует `keepOffKey`. Если в системе уже 0,
    /// ничего не пишем и систему не дёргаем. true — значение пришлось менять.
    @discardableResult
    static func disable() -> Bool {
        rememberUserZero()
        Kit.defaults.set(true, forKey: keepOffKey)
        guard writeZero() else { return false }
        applyToSystem()
        return true
    }

    /// Пишет 0 (без применения), запомнив прежнее значение, если оно ещё не запомнено.
    /// false — там уже 0, писать нечего.
    private static func writeZero() -> Bool {
        let current = usage
        guard current != 0 else { return false }
        let defaults = Kit.defaults
        if defaults.object(forKey: savedKey) == nil {
            defaults.set(current ?? -1, forKey: savedKey)
            // Процесс могут убить сразу после записи 0: прежнее значение должно дойти до диска раньше нуля.
            defaults.synchronize()
        }
        writeUsage(0)
        return true
    }

    /// Результат `reapplyAll`: что система успела вернуть и каким было действие 🌐.
    struct Reapplied {
        var usageFixed = false
        var previousUsage: Int?
        var dictationFixed = false
        var any: Bool { usageFixed || dictationFixed }
    }

    /// Запуск и проверки: вернуть наше «отключено», если систему сбросили (перезапуск, правка настроек,
    /// «OK» в окне диктовки). Все записи сначала, потом один `activateSettings`; переключатель
    /// перезапускаем, только если менялось действие 🌐.
    static func reapplyAll() -> Reapplied {
        var result = Reapplied()
        let current = usage
        if needsReapply(overridden: keepsOff, usage: current), writeZero() {
            result.usageFixed = true
            result.previousUsage = current
        }
        if dictationOverridden, isDictationOnDoubleFn(hotKeys),
           let changed = settingEnabled(hotKeys, id: dictationKey, to: false) {
            writeHotKeys(changed)
            result.dictationFixed = true
        }
        if result.any { applyToSystem(restartSwitcher: result.usageFixed) }
        return result
    }

    /// Отключить действие 🌐 и диктовку на двойном Fn за один проход: записи, потом одно применение.
    /// Для шага «сделать всё автоматически».
    @discardableResult
    static func disableAll() -> Bool {
        rememberUserZero()
        Kit.defaults.set(true, forKey: keepOffKey)
        let usageChanged = writeZero()
        let dictationChanged = writeDictationOff()
        if usageChanged || dictationChanged { applyToSystem(restartSwitcher: usageChanged) }
        return usageChanged || dictationChanged
    }

    /// Что `restore` должен сделать с действием 🌐.
    enum RestoreStep: Equatable {
        case leave
        /// nil — убрать ключ, система действует по умолчанию.
        case write(Int?)
    }

    /// `saved` — запомненное значение (-1: ключа не было), `keptOff` — мы держали 0, `usage` — что в системе сейчас.
    /// Запомненного нет или оно мусор (потеряно, записано чужой версией), а 0 в системе держали мы: возвращаем
    /// умолчание macOS, как вентиляторы возвращаются в «Авто». Хуже оставить 🌐 мёртвой, чем вернуть умолчание.
    /// Мы 0 не держали — значение пользователя не трогаем.
    static func restoreStep(saved: Any?, keptOff: Bool, usage: Int?) -> RestoreStep {
        if let saved = saved as? Int, (-1...3).contains(saved) {
            let value = saved < 0 ? nil : saved
            return usage == value ? .leave : .write(value)
        }
        return keptOff && usage == 0 ? .write(nil) : .leave
    }

    /// Вернуть значение, если его меняли мы. Зовут утилита, когда её выключили или удаляют (при выходе и обновлении она
    /// зовёт `quit`), и центр, когда утилиты уже нет или она ещё не может слушать Fn. Повторный вызов ничего не меняет.
    /// `waitForSystem` — процесс сейчас выйдет: применение настроек и перезапуск переключателя идут здесь, а не в фоне.
    static func restore(waitForSystem: Bool = false) {
        let dictationRestored = restoreDictation()
        let defaults = Kit.defaults
        var usageRestored = false
        if case .write(let value) = restoreStep(saved: defaults.object(forKey: savedKey), keptOff: keepsOff, usage: usage) {
            writeUsage(value)
            usageRestored = true
        }
        // Запомненное убираем после записи: процесс убили посередине — значение осталось, повтор безвреден.
        defaults.removeObject(forKey: savedKey)
        defaults.set(false, forKey: keepOffKey)
        if usageRestored || dictationRestored { applyToSystem(restartSwitcher: usageRestored, wait: waitForSystem) }
    }

    /// Только запись, без `activateSettings`: применяет вызывающий, один раз на все записи.
    private static func writeUsage(_ value: Int?) {
        #if KIT_TEST_DEFAULTS
        if let value { Kit.defaults.set(value, forKey: "Test.FnUsage") } else { Kit.defaults.removeObject(forKey: "Test.FnUsage") }
        return
        #else
        CFPreferencesSetAppValue(key, value.map { NSNumber(value: $0) }, domain)
        CFPreferencesAppSynchronize(domain)
        #endif
    }

    /// macOS не перечитывает AppleFnUsageType сама: TextInputSwitcher держит старое значение и
    /// показывает своё окошко. Просим систему применить настройки и перезапускаем его.
    /// Не на главном потоке, кроме `wait`; трогаем только процесс текущего пользователя.
    private static func applyToSystem(restartSwitcher: Bool = true, wait: Bool = false) {
        #if KIT_TEST_DEFAULTS
        // Стенд записывает, что применение было и ждали ли его.
        Kit.defaults.set(Kit.defaults.integer(forKey: "Test.ApplyCount") + 1, forKey: "Test.ApplyCount")
        Kit.defaults.set(wait, forKey: "Test.ApplyWaited")
        Kit.defaults.set(restartSwitcher, forKey: "Test.ApplyRestart")
        #endif
        // Стенд не перезапускает настройки и TextInputSwitcher настоящей сессии.
        if Kit.standRefuses("activateSettings и перезапуск TextInputSwitcher") { return }
        let work = {
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
        // Процесс сейчас выйдет (удаление): фоновая задача не успела бы начаться.
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
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
        #if KIT_TEST_DEFAULTS
        return Kit.defaults.dictionary(forKey: "Test.HotKeys")
        #else
        CFPreferencesAppSynchronize(hotKeysDomain)
        return CFPreferencesCopyAppValue(hotKeysKey, hotKeysDomain) as? [String: Any]
        #endif
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
    static var dictationOverridden: Bool { Kit.defaults.object(forKey: savedDictationKey) != nil }

    /// Выключить горячую клавишу диктовки; при выключении модуля вернём. true — что-то менялось.
    @discardableResult
    static func disableDictation() -> Bool {
        guard writeDictationOff() else { return false }
        applyToSystem(restartSwitcher: false)
        return true
    }

    /// Запись без применения; false — диктовки на двойном Fn и так нет.
    private static func writeDictationOff() -> Bool {
        guard isDictationOnDoubleFn(hotKeys), let changed = settingEnabled(hotKeys, id: dictationKey, to: false) else { return false }
        Kit.defaults.set(true, forKey: savedDictationKey)
        writeHotKeys(changed)
        return true
    }

    /// Вернуть диктовку, если выключали мы (без применения). true — записали.
    private static func restoreDictation() -> Bool {
        guard dictationOverridden else { return false }
        defer { Kit.defaults.removeObject(forKey: savedDictationKey) }  // после записи, как у 🌐
        guard let changed = settingEnabled(hotKeys, id: dictationKey, to: true) else { return false }
        writeHotKeys(changed)
        return true
    }

    private static func writeHotKeys(_ all: [String: Any]) {
        #if KIT_TEST_DEFAULTS
        Kit.defaults.set(all, forKey: "Test.HotKeys")
        #else
        CFPreferencesSetAppValue(hotKeysKey, all as CFDictionary, hotKeysDomain)
        CFPreferencesAppSynchronize(hotKeysDomain)
        #endif
    }
}
