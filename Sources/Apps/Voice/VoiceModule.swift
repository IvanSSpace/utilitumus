import AVFoundation
import Combine
import SwiftUI

/// «Голос» внутри своей утилиты: микрофон, горячая клавиша, распознавание, вставка и загрузка моделей.
/// `init` ничего не запускает и не трогает хранилище моделей: копия из Finder создаётся рядом с настоящей,
/// и стёрла бы её недокачанные файлы.
@MainActor
final class VoiceModule: SatelliteModule {
    let module = Module.voice
    private var controller: VoiceController { .shared }
    private var store: VoiceModelStore { .shared }

    func start() { controller.start() }

    /// Загрузка модели не переживает остановку: после передачи модулем владеет центр, и два писателя в одну папку не нужны.
    func stop() {
        controller.stop()
        store.cancelAll()
    }

    /// Строка не меняется от диктовки: о смене статуса уходит уведомление, видное всем на этом Mac.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        return modelReady ? controller.hotKeyLabel : "\(controller.hotKeyLabel) · модель не скачана"
    }

    var attention: Bool { !modelReady }

    private var modelReady: Bool { VoiceModel.allCases.contains { store.status($0) == .installed } }

    var setupSteps: [LinkSetupStep] {
        let selected = store.selected
        var busy: String?
        var error: String?
        switch store.status(selected) {
        case let .downloading(progress): busy = "Скачивается… \(Int(progress * 100)) %"
        case .verifying: busy = "Проверяю подпись…"
        case let .failed(message): error = message
        default: break
        }
        return [
            LinkSetupStep(id: "voice.mic", title: "Микрофон", why: "Чтобы слышать тебя; звук остаётся на этом Mac", icon: "mic.fill",
                          done: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
            LinkSetupStep(id: "voice.model", title: "Модель распознавания скачана",
                          why: "Речь распознаётся на этом Mac, нужна модель (\(selected.title), \(Int((Double(selected.sizeBytes) / 1_000_000).rounded())) МБ)",
                          icon: "arrow.down.circle.fill", kind: .system, buttonTitle: "Скачать", done: modelReady, busy: busy, error: error),
            LinkSetupStep(id: "voice.ax", title: "Универсальный доступ",
                          why: "Чтобы текст вставлялся сам, иначе останется нажать ⌘V", icon: "hand.raised.fill", required: false,
                          done: AXIsProcessTrusted()),
        ]
    }

    func performSetupStep(_ id: String) -> String? {
        switch id {
        case "voice.mic": controller.requestMic()
        case "voice.model":
            switch store.status(store.selected) {
            case .notInstalled, .failed: store.download(store.selected)
            default: break
            }
        case "voice.ax": controller.requestAccessibility()
        default: return "Такого шага нет"
        }
        return nil
    }

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }

    /// Только когда меняется то, что видит экран. Фаза записи и уровень звука в `objectWillChange` контроллера тоже
    /// приходят, но состояние от них то же, и пинг, по которому видно, что диктуют, не уходит.
    var changes: AnyPublisher<Void, Never> {
        controller.objectWillChange.merge(with: store.objectWillChange)
            // `objectWillChange` приходит до записи значения.
            .receive(on: DispatchQueue.main)
            .map { [weak self] in self?.controller.wireState }
            .removeDuplicates()
            .map { _ in }
            .eraseToAnyPublisher()
    }

    func windowRoot() -> AnyView { AnyView(VoiceView(voice: VoiceLocalModel.shared)) }
    var windowSize: CGSize { CGSize(width: 760, height: 680) }

    /// Идёт запись, распознавание или загрузка: перезапуск оборвал бы их.
    var mayRestart: Bool { controller.phase == .idle && !store.isBusy }
}
