import Foundation

/// Одноразовый «чистый лист» при первом запуске после обновления до версии со Стором:
/// все модули выключены и не скрыты, человек заново выбирает их в Сторе. Логика чистая: на вход слепок
/// настроек, на выход список записей; сама ничего не пишет и не трогает систему
/// (проверка — Tests/ModuleResetCheck.swift).
///
/// Не трогаем: порядок в панели, настройки самих модулей (правила, пресеты, модели и т.п.), тему,
/// режим страниц, Dock. Разрешения macOS остаются сами.
enum ModuleReset {
    /// Ставится после сброса (и на новой установке), поэтому сброс не повторяется.
    static let flagKey = "Modules.ResetForStore.v1"

    /// Ключи, которые писали самые старые версии (до `ModulesV2`).
    static let legacyPrefixes = [
        "ModuleOrder", "ModuleState.", "ModuleEnabled.", "SelectedModule", "FanConfigs", "MicGuard",
        "UtilitumusKnown", "UtilitumusPrimary", "Stash", "Mixer", "GameMode", "LoadTab", "LoadViewMode",
    ]
    /// Признаки старой версии. Новая установка их не имеет; проверять надо до миграций `ModuleManager`:
    /// они сами пишут `ModulesV2`.
    private static let upgradePrefixes = ["ModuleOn.", "ModuleHidden.", "ModulesV2", "ModulesV3"] + legacyPrefixes

    /// Ключи модуля «Клавиатура»: по ним видно, что системное действие 🌐 или диктовку отключили мы.
    private static let keepOffKey = "Keyboard.KeepSystemFnOff"
    private static let savedUsageKey = "Keyboard.SavedFnUsage"
    private static let savedDictationKey = "Keyboard.SavedDictationEnabled"

    struct Plan: Equatable {
        /// Что записать в UserDefaults. Флаг сброса всегда внутри.
        var writes: [String: Bool]
        /// Вернуть системные настройки Fn (`FnSystemAction.restore()`): старая версия при выходе их не возвращала.
        var restoresSystemFn: Bool
        /// Модули, которых уже ведёт утилита: встроенный выключается записью, а утилиту просит выключиться центр.
        /// Системные настройки у них снимает сама утилита, поэтому за них `restoresSystemFn` не отвечает.
        var askUtility: [String] = []
    }

    /// nil — флаг уже стоит, делать нечего. Иначе: на новой установке только флаг, на обновлении
    /// ещё и сброс модулей.
    static func plan(snapshot: [String: Any], moduleIDs: [String], handedOver: (String) -> Bool = { _ in false }) -> Plan? {
        guard snapshot[flagKey] == nil else { return nil }
        var writes = [flagKey: true]
        let isUpgrade = snapshot.keys.contains { key in upgradePrefixes.contains { key.hasPrefix($0) } }
        guard isUpgrade else { return Plan(writes: writes, restoresSystemFn: false) }
        for id in moduleIDs {
            writes["ModuleOn.\(id)"] = false
            writes["ModuleHidden.\(id)"] = false
        }
        // KeepSystemFnOff — Bool: false значит «не просили». Остальные два — само наличие значения
        // (в SavedFnUsage 0 — полноценное прежнее значение, поэтому как Bool его читать нельзя).
        let fnIntent = (snapshot[keepOffKey] as? Bool) == true
            || snapshot[savedUsageKey] != nil || snapshot[savedDictationKey] != nil
        let external = moduleIDs.filter(handedOver)
        // Клавиатуру ведёт утилита: 🌐 принадлежит ей, центр его не трогает.
        return Plan(writes: writes, restoresSystemFn: fnIntent && !external.contains("keyboard"), askUtility: external)
    }
}
