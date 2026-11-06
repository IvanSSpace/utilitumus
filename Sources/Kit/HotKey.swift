import AppKit
import Carbon.HIToolbox

/// Сочетание клавиш: keyCode + модификаторы Carbon (cmdKey, optionKey, controlKey, shiftKey).
enum VoiceHotKey {
    static let defaultKeyCode: UInt32 = UInt32(kVK_Space)
    static let defaultModifiers: UInt32 = UInt32(controlKey | optionKey)

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static let names: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
        7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        49: "Space", 36: "Return", 48: "Tab", 51: "⌫", 117: "⌦", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                   105, 107, 113, 106, 64, 79, 80, 90]

    /// Годится как горячая: известная клавиша и либо модификатор (⌘⌥⌃), либо F-клавиша.
    static func isAcceptable(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard names[keyCode] != nil else { return false }
        if functionKeys.contains(keyCode) { return true }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (names[keyCode] ?? "?")
    }
}

/// То, чему назначают сочетание: «Голос» и «Буфер».
@MainActor
protocol HotKeyTarget: AnyObject {
    func setHotKey(keyCode: UInt32, modifiers: UInt32)
    func resetHotKey()
    func suspendHotKey()
    func resumeHotKey()
}

/// Запись сочетания клавиш: пока идёт, следующее нажатое сочетание назначается, остальное глотается.
@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private weak var controller: (any HotKeyTarget)?

    func start(_ controller: some HotKeyTarget) {
        stop()
        self.controller = controller
        isRecording = true
        // Текущее сочетание не должно срабатывать, пока ждём новое.
        controller.suspendHotKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { self?.handle(keyCode: keyCode, flags: flags) }
            return nil
        }
        // Клик мимо отменяет; клик по самой кнопке сразу запустит запись заново.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.stop() }
            return event
        }
    }

    private func handle(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard let controller else { return stop() }
        let modifiers = VoiceHotKey.carbonModifiers(flags)
        switch keyCode {
        case 53 where modifiers == 0:
            stop()
        case 51 where modifiers == 0, 117 where modifiers == 0:
            controller.resetHotKey()
            stop()
        default:
            if VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers) {
                controller.setHotKey(keyCode: keyCode, modifiers: modifiers)
                stop()
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        if isRecording { controller?.resumeHotKey() }
        isRecording = false
    }
}
