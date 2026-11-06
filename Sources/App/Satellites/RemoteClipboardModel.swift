import Combine
import Foundation

/// Модель вкладки «Буфер», когда модуль ведёт утилита. Записей истории здесь нет: счётчики и пять строк из состояния.
/// Кроме экрана, центр делает одно дело: передаёт утилите ключ истории из своей прежней записи Связки ключей,
/// когда утилита о нём просит (`keyState == .waiting`).
@MainActor
final class RemoteClipboardModel: RemoteModuleModel<ClipboardState, ClipboardAction>, ClipboardModel {
    private let link: RemoteModuleLink
    private let keyring: ClipboardKeyring
    private var handoverRunning = false
    private var stateSub: AnyCancellable?

    init(id: String, keyring: ClipboardKeyring? = nil, link: RemoteModuleLink? = nil,
         canRead: @escaping () -> Bool) {
        #if KIT_TEST_DEFAULTS
        // Стенд не касается настоящей Связки ключей.
        let keyring = keyring ?? MemoryClipboardKeyring.forStand()
        #else
        let keyring = keyring ?? SystemClipboardKeyring()
        #endif
        let link = link ?? .live(id: id)
        self.link = link
        self.keyring = keyring
        super.init(id: id,
                   initial: ClipboardState(totalCount: 0, historyCount: 0, spaces: [], spaceCounts: [:], recent: [],
                                           hotKeyLabel: VoiceHotKey.label(keyCode: ClipboardController.defaultKeyCode,
                                                                          modifiers: ClipboardController.defaultModifiers),
                                           hotKeyError: nil, storeError: nil, storeNotice: nil,
                                           limit: ClipboardPolicy.defaultLimit, excludedApps: [], axTrusted: false),
                   link: link, canRead: canRead,
                   optimistic: { state, action in
                       switch action {
                       case .setLimit(let value): state.limit = value
                       case .addExcluded(let id):
                           if !state.excludedApps.contains(id) { state.excludedApps.append(id) }
                       case .removeExcluded(let id): state.excludedApps.removeAll { $0 == id }
                       default: break
                       }
                   })
        stateSub = $state.map(\.keyState).removeDuplicates().sink { [weak self] keyState in
            if keyState == .waiting { self?.startHandover() }
        }
    }

    /// Один проход за ожидание: отказ не повторяется, пока утилита не попросит снова (новый запуск).
    private func startHandover() {
        guard !handoverRunning, canHandOver() else { return }
        handoverRunning = true
        let link = link
        let handover = ClipboardKeyHandover(
            keyring: keyring,
            send: { data in try await link.action(data) },
            readKeyState: { try JSONDecoder().decode(ClipboardState.self, from: try await link.state()).keyState })
        Task { @MainActor in
            let result = await handover.run()
            handoverRunning = false
            // Без ключа и без его следов: только исход.
            fputs("Буфер: передача ключа — \(Self.describe(result))\n", stderr)
            refresh()
        }
    }

    private func canHandOver() -> Bool { ModuleManager.shared.isExternal(.clipboard) }

    private static func describe(_ result: ClipboardKeyHandover.Result) -> String {
        switch result {
        case .done: return "готово"
        case .nothingToHand: return "прежней записи нет"
        case .failed(let reason): return reason
        }
    }

    // MARK: ClipboardModel

    var totalCount: Int { state.totalCount }
    var historyCount: Int { state.historyCount }
    var spaces: [ClipSpace] { state.spaces }
    func count(inSpace id: UUID) -> Int { state.spaceCounts[id.uuidString] ?? 0 }
    var recent: [ClipRecentRow] { state.recent }
    var hotKeyLabel: String { state.hotKeyLabel }
    var hotKeyError: String? { state.hotKeyError }
    var storeError: String? { state.storeError }
    var storeNotice: String? { state.storeNotice }
    var limit: Int { state.limit }
    var excludedApps: [String] { state.excludedApps }
    var axTrusted: Bool { state.axTrusted }

    func togglePanel() { send(.togglePanel) }
    func refreshPermissions() { send(.refreshPermissions) }
    func requestAccessibility() { send(.requestAccessibility) }
    func clearHistory() { send(.clearHistory) }
    func setLimit(_ value: Int) { send(.setLimit(value: value)) }
    func addSpace(name: String, colorID: String) { send(.addSpace(name: name, colorID: colorID)) }
    func renameSpace(_ id: UUID, to name: String) { send(.renameSpace(id: id, name: name)) }
    func setColor(_ id: UUID, _ colorID: String) { send(.setColor(id: id, colorID: colorID)) }
    func moveSpace(_ id: UUID, by offset: Int) { send(.moveSpace(id: id, by: offset)) }
    func deleteSpace(_ id: UUID) { send(.deleteSpace(id: id)) }
    func addExcluded(_ bundleID: String) { send(.addExcluded(bundleID: bundleID)) }
    func removeExcluded(_ bundleID: String) { send(.removeExcluded(bundleID: bundleID)) }
    func setHotKey(keyCode: UInt32, modifiers: UInt32) { send(.setHotKey(keyCode: keyCode, modifiers: modifiers)) }
    func resetHotKey() { send(.resetHotKey) }
    func suspendHotKey() { send(.suspendHotKey) }
    func resumeHotKey() { send(.resumeHotKey) }
}
