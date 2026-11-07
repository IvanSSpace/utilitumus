import Foundation

/// Событие клавиатуры/мыши, как его видит детектор. Без AppKit и CoreGraphics: проверяется тестом.
enum FnEvent: Equatable {
    /// flagsChanged с keyCode 63. `others` — зажат ли ещё какой-то модификатор (⇧ ⌃ ⌥ ⌘).
    case fn(down: Bool, others: Bool)
    /// flagsChanged любой другой клавиши-модификатора.
    case modifier
    case keyDown
    /// NX_SYSDEFINED: медиа-клавиши и Fn+F-ряд.
    case sysDefined
    case mouseDown
}

/// «Чистый тап» Fn: нажали и отпустили, и между этим больше ничего не было.
/// Fn+стрелка, Fn+Delete, Fn+F11, Fn+Shift и Fn+клик тапом не считаются.
struct FnTapDetector {
    var trigger: FnTrigger = .onRelease
    /// Fn зажат, и с момента нажатия ничего постороннего не случилось.
    private var clean = false
    /// Что оборвало чистое нажатие Fn на последнем событии (для журнала); nil — ничего.
    private(set) var cancelledBy: FnEvent?

    init(trigger: FnTrigger = .onRelease) { self.trigger = trigger }

    /// true — раскладку надо переключить прямо сейчас.
    mutating func handle(_ event: FnEvent) -> Bool {
        cancelledBy = nil
        switch event {
        case .fn(let down, let others):
            if down {
                clean = !others
                return clean && trigger == .onPress
            }
            let wasClean = clean
            clean = false
            return wasClean && !others && trigger == .onRelease
        case .modifier, .keyDown, .sysDefined, .mouseDown:
            if clean && trigger == .onRelease { cancelledBy = event }
            clean = false
            return false
        }
    }
}
