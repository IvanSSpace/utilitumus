import Combine
import Foundation

/// Модели модулей, которых ведут утилиты. Одна строка на модуль, и это единственное место в центре, где модуль назван.
/// Модель берётся по образцу `RemoteAwakeModel.shared`: `canRead` — «ведёт утилита», `follow` — статус реестра.
/// Строки разделены комментариями, чтобы одновременные правки разных модулей сливались без конфликтов.
@MainActor
enum RemoteModules {
    #if KIT_TEST_DEFAULTS
    /// Проверка подставляет модели с управляемой связью: настоящая утилита ей не нужна.
    static var testModels: [Module: any RemoteModuleSurface] = [:]
    #endif

    static func model(_ module: Module) -> (any RemoteModuleSurface)? {
        #if KIT_TEST_DEFAULTS
        if let fixture = testModels[module] { return fixture }
        #endif
        switch module {
        case .awake: return RemoteAwakeModel.shared
        // sound
        case .sound: return RemoteSoundModel.shared
        // mouse
        case .mouse: return RemoteMouseModel.shared
        // mixer
        case .mixer: return RemoteMixerModel.shared
        // stash
        case .stash: return RemoteStashModel.shared
        // keyboard
        case .keyboard: return RemoteKeyboardModel.shared
        // browser
        // Модели нет: экран читает общий домен настроек сам (`RemoteBrowserPage`), карточка идёт из статуса утилиты.
        case .browser: return nil
        // load
        case .load: return RemoteLoadModel.shared
        // voice
        case .voice: return RemoteVoiceModel.shared
        // clipboard
        case .clipboard: return RemoteClipboardModel.shared
        // fans
        case .fans: return RemoteFansModel.shared
        }
    }

    /// Только модели ведомых утилитой модулей: остальным нечего читать.
    static func external(_ modules: ModuleManager) -> [(Module, any RemoteModuleSurface)] {
        Module.allCases.compactMap { module in
            guard modules.isExternal(module), let model = model(module) else { return nil }
            return (module, model)
        }
    }
}
