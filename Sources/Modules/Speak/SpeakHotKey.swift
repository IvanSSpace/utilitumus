import AppKit
import Carbon.HIToolbox

/// Глобальное сочетание. Настоящее — `CarbonSpeakHotKey`; проверки ставят подмену и жмут его сами.
@MainActor
protocol SpeakHotKeyBinding: AnyObject {
    var onPress: (() -> Void)? { get set }
    /// Занять сочетание. false — его держит другая программа.
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool
    /// Отпустить. Повторный вызов безвреден.
    func unregister()
}

/// Сочетание через Carbon, как у «Голоса»: пока оно занято, система не отдаёт его программам.
@MainActor
final class CarbonSpeakHotKey: SpeakHotKeyBinding {
    var onPress: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    nonisolated fileprivate static let signature: OSType = 0x5350454B  // 'SPEK'
    /// Кому отдать нажатие: обработчик Carbon — функция C, захватить объект он не может.
    fileprivate static weak var current: CarbonSpeakHotKey?

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        Self.current = self
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        InstallEventHandler(GetApplicationEventTarget(), speakHotKeyCallback, 1, &types, nil, &handlerRef)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            hotKeyRef = nil
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    fileprivate func pressed() { onPress?() }
}

/// Обработчик Carbon: только своя подпись, нажатие уходит на главный поток.
private func speakHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == CarbonSpeakHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { CarbonSpeakHotKey.current?.pressed() }
    }
    return noErr
}
