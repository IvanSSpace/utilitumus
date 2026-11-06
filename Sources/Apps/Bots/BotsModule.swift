import Combine
import SwiftUI

/// «Боты» внутри своей утилиты. Замеры идут, только пока открыт экран (аренда `screenOpen`); без неё утилита ничего
/// не опрашивает. Команды запускает один `BotRunner`, и только по id бота и кнопке из bots.toml.
@MainActor
final class BotsModule: SatelliteModule {
    let module = Module.bots
    private var leased = false
    private var running = false

    /// Ничего не читает и не запускает.
    init() {}

    private var store: BotsStore { BotsStore.shared }

    /// Один замер при запуске: строке статуса и быстрым действиям нужно знать, кто работает. Дальше только по аренде.
    func start() {
        running = true
        store.refresh()
    }

    func stop() {
        running = false
        leased = false
        store.shutDown()
    }

    func screenOpen(_ open: Bool) {
        guard running, open != leased else { return }
        leased = open
        if open { store.screenAppeared() } else { store.screenDisappeared() }
    }

    /// Только счёт: имена ботов и аптайм уходят всем, кто спросит статус.
    func statusLine(passiveReason: String?) -> String {
        passiveReason ?? BotsText.summary(store.state)
    }

    var attention: Bool { store.state.file.kind == .unsafe }

    /// Не больше трёх: меню не должно разрастаться вместе с файлом.
    var quickActions: [LinkQuickAction] {
        guard running, store.state.file.kind == .ok else { return [] }
        let specs = store.specsNow()
        return store.state.bots.compactMap { bot -> LinkQuickAction? in
            let on = bot.state == .running || bot.state == .partial
            let verb: BotVerb = on ? .stop : .start
            guard bot.verbs.contains(verb), case .argv(let argv)? = specs.first(where: { $0.id == bot.id })?.commands[verb] else { return nil }
            return LinkQuickAction(
                title: "\(verb.title) \(bot.name)", icon: on ? "stop.circle" : "play.circle",
                action: LinkWire.encoded(BotsAction.quick(id: bot.id, verb: verb, sum: BotRunner.fingerprint(argv))),
                confirm: LinkConfirm(title: "\(verb.title) \(bot.name)?", message: "Выполнит \(BotsStore.shown(argv)).", button: verb.title))
        }
        .prefix(3).map { $0 }
    }

    func state() -> Data { LinkWire.encoded(store.state) }

    /// Остановленный модуль команд не запускает.
    func handle(_ action: Data) -> Data {
        guard running else {
            return LinkWire.encoded(LinkReply(state: store.state, error: "Модуль сейчас не работает"))
        }
        return store.handle(action)
    }

    var changes: AnyPublisher<Void, Never> { store.objectWillChange.map { _ in }.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(BotsView(model: store)) }
    var windowSize: CGSize { CGSize(width: 640, height: 640) }

    /// Команда бота выполняется: перезапуск оборвал бы её на середине.
    var mayRestart: Bool { !store.state.running }

    #if KIT_TEST_DEFAULTS
    func standCommand() { store.refresh() }
    #endif
}
