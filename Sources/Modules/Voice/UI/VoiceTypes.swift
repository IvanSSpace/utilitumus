import CoreAudio
import Foundation

/// Модели распознавания речи для sherpa-onnx. Скачиваются по кнопке (сотни мегабайт
/// в приложение не вшиваются); хэш каждого архива вшит сюда и сверяется после загрузки.
enum VoiceModel: String, CaseIterable, Identifiable {
    case gigaam
    case parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam: return "GigaAM v3 — русский"
        case .parakeet: return "Parakeet v3 — многоязычный"
        }
    }

    /// Короткая подпись под названием: размер и сильные стороны.
    var subtitle: String {
        switch self {
        case .gigaam: return "170 МБ · лучший для русского, сам ставит знаки препинания"
        case .parakeet: return "487 МБ · 25 европейских языков, включая русский и английский"
        }
    }

    var license: String {
        switch self {
        case .gigaam: return "MIT"
        case .parakeet: return "CC-BY-4.0"
        }
    }

    /// Архив с моделью в релизах sherpa-onnx.
    var url: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(folderName).tar.bz2")!
    }

    var sha256: String {
        switch self {
        case .gigaam: return "f9620a0099019c6afcee26525ef9ed3297fa50dd5691c1902af0c948fc1a470b"
        case .parakeet: return "1495e91b59d7fc53ddca91f3431758ec99f8fa253fdb0e1e851be0f72b14b0f9"
        }
    }

    /// Размер архива в байтах — для прогресса, когда сервер не прислал Content-Length.
    var sizeBytes: Int64 {
        switch self {
        case .gigaam: return 170_197_019
        case .parakeet: return 487_211_443
        }
    }

    /// Имя папки: оно же имя корневой папки внутри архива.
    var folderName: String {
        switch self {
        case .gigaam: return "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
        case .parakeet: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
        }
    }

    /// Файлы, без которых модель не работает.
    var requiredFiles: [String] {
        switch self {
        case .gigaam: return ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
        case .parakeet: return ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        }
    }
}

enum VoiceModelStatus: Equatable, Codable {
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case installed
    case failed(String)
}

enum VoiceMode: String, CaseIterable, Identifiable {
    case toggle
    case hold
    var id: String { rawValue }
    var title: String { self == .toggle ? "Нажал — нажал" : "Пока держу" }
}

enum VoiceKeys {
    static let keyCode = "Voice.HotKeyCode"
    static let modifiers = "Voice.HotKeyModifiers"
    static let mode = "Voice.Mode"
    static let mic = "Voice.MicUID"
    static let excluded = "Voice.ExcludedApps"
}

/// Модели на диске: где лежат, какая выбрана, что установлено. Это читает и экран центра, хранилище с загрузками ему не нужно.
enum VoiceModelFiles {
    static let selectedKey = "Voice.Model"

    /// Application Support/Utilitumus/Voice/Models. В сборке со швом `KIT_TEST_DEFAULTS` это временная папка своего suite:
    /// домашний каталог в ней не участвует, потому что утилита стенда под launchd живёт с настоящим домом
    /// и иначе чистила бы и стирала настоящие модели.
    static var modelsRoot: URL {
        #if KIT_TEST_DEFAULTS
        let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? "local.utilitumus.test.kit"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("utilitumus-test-models/\(suite)/Voice/Models", isDirectory: true)
        Kit.assertStandPath(root, "модели Голоса")
        return root
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utilitumus/Voice/Models", isDirectory: true)
        #endif
    }

    static func folder(of model: VoiceModel) -> URL {
        modelsRoot.appendingPathComponent(model.folderName, isDirectory: true)
    }

    static func isInstalled(_ model: VoiceModel) -> Bool {
        let dir = folder(of: model)
        return model.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Выбранная модель, по умолчанию GigaAM.
    static var selected: VoiceModel {
        Kit.defaults.string(forKey: selectedKey).flatMap(VoiceModel.init(rawValue:)) ?? .gigaam
    }

    static func delete(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: folder(of: model))
    }
}

/// Микрофоны для списка на экране: читается на месте, разрешений не требует.
enum VoiceInputs {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Устройства, у которых есть вход.
    static func devices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
