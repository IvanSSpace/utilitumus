import Combine
import CryptoKit
import SwiftUI

/// «Буфер» внутри своей утилиты. Хранилище открывается не на главном потоке: чтение ключа может показать системный запрос,
/// а центр ждёт ответа 2 с. Пока ключа нет или история не открылась, на экране видно причину; нового ключа не бывает.
@MainActor
final class ClipboardModule: SatelliteModule {
    let module = Module.clipboard
    private let controller = ClipboardController.shared
    private let keyring: ClipboardKeyring
    private let directory: URL
    /// Связка и каталог истории выбираются здесь, в одном месте. В сборке для стендов их нет: ни настоящей связки,
    /// ни настоящего `index.bin`.
    private let keyQueue = DispatchQueue(label: "local.utilitumus.app.clipboard.key", qos: .userInitiated)

    private var running = false
    /// Номер запуска: ответ фонового открытия, пережившего `stop`, выбрасывается.
    private var epoch = 0
    private var keyState: ClipboardKeyState?
    /// Идёт чтение ключа или проверка присланного: второго не начинаем.
    private var verifying = false
    private let own = PassthroughSubject<Void, Never>()

    init(keyring: ClipboardKeyring? = nil, directory: URL? = nil) {
        #if KIT_TEST_DEFAULTS
        self.keyring = keyring ?? MemoryClipboardKeyring.forStand()
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-stand-\(UUID().uuidString)", isDirectory: true)
        controller.observesSystem = false
        #else
        self.keyring = keyring ?? SystemClipboardKeyring()
        self.directory = directory ?? ClipboardStore.defaultDirectory
        #endif
        controller.storeOpener = { [weak self] in self?.openStore() }
    }

    func start() {
        guard !running else { return }
        running = true
        controller.start()
    }

    /// Пассивная и остановленная утилита не держит историю: файл ведёт кто-то один.
    func stop() {
        running = false
        epoch += 1
        verifying = false
        keyState = nil
        controller.stop()
        controller.detachStore()
        own.send()
    }

    // MARK: - Открытие хранилища

    private func openStore() {
        // Ждёт ключ или отказ уже разобран: каждое открытие панели не должно заново трогать Связку ключей.
        guard running, !verifying, keyState != .waiting, keyState != .failed else { return }
        verifying = true
        let epoch = epoch
        let limit = controller.limit
        let resolver = ClipboardKeyResolver(keyring: keyring, directory: directory)
        let directory = directory
        keyQueue.async {
            let outcome = resolver.resolve()
            // Хранилище собирается здесь же: чтение и расшифровка индекса тоже не для главного потока.
            let store: ClipboardStore? = {
                guard case .ready(let key) = outcome else { return nil }
                return ClipboardStore(directory: directory, key: SymmetricKey(data: key), limit: limit)
            }()
            nonisolated(unsafe) let handoff = store
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishOpening(epoch, outcome, handoff) }
            }
        }
    }

    private func finishOpening(_ epoch: Int, _ outcome: ClipboardKeyOutcome, _ store: ClipboardStore?) {
        guard running, epoch == self.epoch else { return }
        verifying = false
        switch outcome {
        case .ready:
            keyState = .ready
            if let store { controller.attachOpened(store) }
        case .needsHandover:
            keyState = .waiting
            controller.storeUnavailable("Ключ истории передаёт Utilitumus: открой его, и история заработает. Старая история не тронута")
        case .failed(let failure):
            keyState = .failed
            controller.storeUnavailable(failure.message)
        }
        own.send()
    }

    // MARK: - Передача ключа

    /// Сообщение центра с ключом. Принимается только от соединения центра, только пока утилита ждёт ключ и не проверяет
    /// другой. Ответ говорит лишь «принято к проверке»: готовность видна в состоянии, когда утилита сама прочитала
    /// свою запись и открыла ею историю.
    private func receiveKey(_ message: ClipboardKeyMessage) -> Data {
        guard LinkCaller.isHub, running, keyState == .waiting, !verifying else {
            return LinkWire.encoded(ClipboardKeyReply(received: false))
        }
        verifying = true
        let epoch = epoch
        let key = message.key
        let resolver = ClipboardKeyResolver(keyring: keyring, directory: directory)
        let limit = controller.limit
        let directory = directory
        keyQueue.async {
            let rejected = resolver.accept(key)
            // Дальше как при обычном запуске: своя запись читается заново и открывает индекс.
            let outcome = rejected.map(ClipboardKeyOutcome.failed) ?? resolver.resolve()
            let store: ClipboardStore? = {
                guard case .ready(let own) = outcome else { return nil }
                return ClipboardStore(directory: directory, key: SymmetricKey(data: own), limit: limit)
            }()
            nonisolated(unsafe) let handoff = store
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishOpening(epoch, outcome, handoff) }
            }
        }
        return LinkWire.encoded(ClipboardKeyReply(received: true))
    }

    /// Центр забирает ключ перед удалением утилиты. Только от центра. Чтение своей записи здесь идёт на главном
    /// потоке: запись принадлежит этому процессу, системный запрос по ней не показывается.
    private func returnKey(_ message: ClipboardKeyReturnMessage) -> Data {
        guard LinkCaller.isHub, !verifying else {
            return LinkWire.encoded(ClipboardKeyReturnReply(key: nil, error: "Утилита занята ключом или вызов не от Utilitumus"))
        }
        let resolver = ClipboardKeyResolver(keyring: keyring, directory: directory)
        switch message {
        case .returnKey: return LinkWire.encoded(resolver.keyToReturn())
        case .dropKey: return LinkWire.encoded(ClipboardKeyReturnReply(key: nil, error: resolver.dropOwn()))
        }
    }

    // MARK: - Статус

    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        guard running else { return "Выключен" }
        switch keyState {
        case .waiting: return "Ждёт ключ истории от Utilitumus"
        case .failed: return "Нет доступа к истории"
        case .ready, .none: return "Помнит буфер обмена"
        }
    }

    var attention: Bool { running && keyState == .failed }

    var quickActions: [LinkQuickAction] {
        guard running, keyState == .ready else { return [] }
        return [LinkQuickAction(title: "Открыть панель", icon: "rectangle.bottomthird.inset.filled",
                                action: LinkWire.encoded(ClipboardAction.togglePanel))]
    }

    private static let accessibilityStep = "accessibility"

    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: Self.accessibilityStep, title: "Универсальный доступ",
                       why: "Чтобы выбранная запись вставлялась сама, иначе останется нажать ⌘V", icon: "hand.raised",
                       buttonTitle: "Разрешить", required: false, done: controller.axTrusted)]
    }

    func performSetupStep(_ id: String) -> String? {
        guard id == Self.accessibilityStep else { return "Такого шага нет" }
        controller.requestAccessibility()
        return nil
    }

    // MARK: - Состояние и действия

    private var wireState: ClipboardState {
        var state = controller.wireState
        state.keyState = keyState
        return state
    }

    func state() -> Data { LinkWire.encoded(wireState) }

    func handle(_ data: Data) -> Data {
        if let message = LinkWire.decodeAction(ClipboardKeyMessage.self, from: data, limit: ClipboardKeyMessage.limit) {
            return receiveKey(message)
        }
        if let message = LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: data, limit: ClipboardKeyReturnMessage.limit) {
            return returnKey(message)
        }
        return LinkWire.handle(data, as: ClipboardAction.self, limit: 1024, state: { wireState }) { action in
            // Остановленная утилита историю не трогает, даже если действие дошло.
            guard running else { return "Модуль выключен" }
            return controller.handle(action)
        }
    }

    var changes: AnyPublisher<Void, Never> {
        controller.objectWillChange.map { _ in }.merge(with: own).eraseToAnyPublisher()
    }

    func screenOpen(_ open: Bool) {
        if open && running { controller.refreshPermissions() }
    }

    func windowRoot() -> AnyView { AnyView(ClipboardView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 520, height: 520) }

    #if KIT_TEST_DEFAULTS
    /// Стенд: сигнал USR1 кладёт в историю выдуманные записи, буфер обмена не нужен.
    func standCommand() {
        guard let store = controller.store else { return }
        ClipboardStandFixture.seed(store)
        controller.attach(store)
    }
    #endif
}
