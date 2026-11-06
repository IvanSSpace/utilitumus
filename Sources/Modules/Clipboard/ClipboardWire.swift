import Foundation
import Carbon.HIToolbox

/// Строка «Последних записей»: только то, что на ней видно.
struct ClipRecentRow: Codable, Equatable {
    var title: String
    /// Для значка программы.
    var sourceBundleID: String?
    var date: Date

    static let limit = 5
    /// В колонку шириной 270 столько даже узких символов не влезает.
    static let maxTitleLength = 120

    static func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .text: return (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
        case .link: return item.host ?? item.text ?? ""
        case .image: return "Картинка \(item.imageWidth.map { "\($0)×\(item.imageHeight ?? 0)" } ?? "")"
        case .file: return (item.filePaths?.first.map { ($0 as NSString).lastPathComponent }) ?? "Файл"
        }
    }

    /// Для встроенного экрана: названия целиком. Текст длиннее примерно 10 000 символов система усекает
    /// чуть иначе, чем короткий, поэтому обрезка здесь сдвинула бы пиксели.
    static func rows(from items: some Sequence<ClipItem>) -> [ClipRecentRow] {
        items.prefix(limit).map { ClipRecentRow(title: title($0), sourceBundleID: $0.sourceBundleID, date: $0.date) }
    }

    /// Для состояния: названия обрезаны, записей программ из `excluded` нет.
    static func wireRows(from items: [ClipItem], hiding excluded: [String]) -> [ClipRecentRow] {
        rows(from: items.lazy.filter { item in !excluded.contains { $0 == item.sourceBundleID } }).map {
            ClipRecentRow(title: String($0.title.prefix(maxTitleLength)), sourceBundleID: $0.sourceBundleID, date: $0.date)
        }
    }
}

/// То, что экран показывает. Записей истории здесь нет и быть не должно: только счётчики и пять строк.
struct ClipboardState: Codable, Equatable {
    var totalCount: Int
    var historyCount: Int
    var spaces: [ClipSpace]
    /// Строка с id пространства → число записей в нём.
    var spaceCounts: [String: Int]
    var recent: [ClipRecentRow]
    var hotKeyLabel: String
    var hotKeyError: String?
    var storeError: String?
    var storeNotice: String?
    var limit: Int
    var excludedApps: [String]
    var axTrusted: Bool
}

extension ClipboardState {
    /// `recent` отдельно: строки собираются из записей, а записей у протокола модели нет.
    @MainActor
    init(model: some ClipboardModel, recent: [ClipRecentRow]) {
        self.init(totalCount: model.totalCount, historyCount: model.historyCount, spaces: model.spaces,
                  spaceCounts: Dictionary(uniqueKeysWithValues: model.spaces.map { ($0.id.uuidString, model.count(inSpace: $0.id)) }),
                  recent: recent, hotKeyLabel: model.hotKeyLabel, hotKeyError: model.hotKeyError,
                  storeError: model.storeError, storeNotice: model.storeNotice, limit: model.limit,
                  excludedApps: model.excludedApps, axTrusted: model.axTrusted)
    }
}

/// Что экран может попросить. Больше модуль ничего не примет.
enum ClipboardAction: Codable, Equatable {
    case togglePanel
    case refreshPermissions
    case requestAccessibility
    case clearHistory
    case setLimit(value: Int)
    case addSpace(name: String, colorID: String)
    case renameSpace(id: UUID, name: String)
    case setColor(id: UUID, colorID: String)
    case moveSpace(id: UUID, by: Int)
    case deleteSpace(id: UUID)
    case addExcluded(bundleID: String)
    case removeExcluded(bundleID: String)
    case suspendHotKey
    case resumeHotKey
    case setHotKey(keyCode: UInt32, modifiers: UInt32)
    case resetHotKey
}

enum ClipboardWireRules {
    static let maxNameBytes = 256
    static let maxSpaces = 100
    static let maxExcludedApps = 200
    static let maxBundleIDBytes = 255

    /// Имя без пробелов по краям; nil — пустое, слишком длинное или с управляющими символами.
    static func cleanName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.utf8.count <= maxNameBytes,
              !clean.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return clean
    }

    static func isColor(_ id: String) -> Bool { ClipPalette.all.contains { $0.id == id } }

    static func isBundleID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxBundleIDBytes else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: return true  // 0-9 A-Z a-z - . _
            default: return false
            }
        }
    }

    static func isHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard modifiers & ~UInt32(cmdKey | shiftKey | optionKey | controlKey) == 0 else { return false }
        return VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers)
    }
}

extension ClipboardModel {
    /// Действие от экрана: сначала проверка, изменения только после неё. Вернёт текст, если не выполнено.
    /// У `addSpace` и `addExcluded` модель может отказать молча, поэтому результат сверяется после вызова.
    func handle(_ action: ClipboardAction) -> String? {
        func known(_ id: UUID) -> Bool { spaces.contains { $0.id == id } }
        let noSpace = "Такого пространства нет"
        switch action {
        case .togglePanel: togglePanel()
        case .refreshPermissions: refreshPermissions()
        case .requestAccessibility: requestAccessibility()
        case .suspendHotKey: suspendHotKey()
        case .resumeHotKey: resumeHotKey()
        case .resetHotKey: resetHotKey()
        case .clearHistory:
            guard historyCount > 0 else { return "История уже пуста" }
            clearHistory()
        case .setLimit(let value):
            guard ClipboardPolicy.limits.contains(value) else { return "Такого размера истории нет" }
            setLimit(value)
        case .addSpace(let name, let colorID):
            guard let clean = ClipboardWireRules.cleanName(name) else { return "Неподходящее название" }
            guard ClipboardWireRules.isColor(colorID) else { return "Такого цвета нет" }
            let before = spaces.count
            guard before < ClipboardWireRules.maxSpaces else { return "Слишком много пространств" }
            addSpace(name: clean, colorID: colorID)
            guard spaces.count > before else { return "История не ведётся" }
        case .renameSpace(let id, let name):
            guard known(id) else { return noSpace }
            guard let clean = ClipboardWireRules.cleanName(name) else { return "Неподходящее название" }
            renameSpace(id, to: clean)
        case .setColor(let id, let colorID):
            guard known(id) else { return noSpace }
            guard ClipboardWireRules.isColor(colorID) else { return "Такого цвета нет" }
            setColor(id, colorID)
        case .moveSpace(let id, let offset):
            guard let from = spaces.firstIndex(where: { $0.id == id }) else { return noSpace }
            guard offset == 1 || offset == -1, spaces.indices.contains(from + offset) else { return "Двигать некуда" }
            moveSpace(id, by: offset)
        case .deleteSpace(let id):
            guard known(id) else { return noSpace }
            deleteSpace(id)
        case .addExcluded(let bundleID):
            guard ClipboardWireRules.isBundleID(bundleID) else { return "Неподходящая программа" }
            guard !excludedApps.contains(bundleID) else { return "Эта программа уже в списке" }
            guard excludedApps.count < ClipboardWireRules.maxExcludedApps else { return "Слишком много программ" }
            addExcluded(bundleID)
            guard excludedApps.contains(bundleID) else { return "Эту программу исключить нельзя" }
        case .removeExcluded(let bundleID):
            guard excludedApps.contains(bundleID) else { return "Этой программы нет в списке" }
            removeExcluded(bundleID)
        case .setHotKey(let keyCode, let modifiers):
            guard ClipboardWireRules.isHotKey(keyCode: keyCode, modifiers: modifiers) else { return "Такое сочетание не подходит" }
            setHotKey(keyCode: keyCode, modifiers: modifiers)
        }
        return nil
    }
}

extension ClipboardController {
    /// Записи программ из исключений наружу не идут, даже если попали в историю до включения исключения.
    var wireState: ClipboardState {
        ClipboardState(model: self, recent: ClipRecentRow.wireRows(from: items, hiding: excludedApps))
    }
}
