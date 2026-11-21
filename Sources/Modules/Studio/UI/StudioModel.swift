import AppKit
import Foundation

/// Всё, что экран «Студия» берёт у своей модели. Кто за ней стоит, контроллер в утилите или модель вкладки в центре,
/// экран не знает.
@MainActor
protocol StudioModel: ObservableObject {
    var state: StudioState { get }
    func setFolder(_ path: String)
    /// Новый одноразовый код входа.
    func newLogin()
    /// «Открыть в браузере»: просит новый код и открывает адрес, когда код пришёл.
    func openInBrowser()
    /// Номер кода входа, который ушёл в браузер: страница в окне его не берёт, второй вход по одноразовому коду не пройдёт.
    var browserLogin: Int { get }
}

/// Открыть адрес в браузере по умолчанию. Стенд отказывает: из проверки настоящий браузер не запускается.
enum StudioOpen {
    @MainActor static func inBrowser(_ url: URL) {
        guard !Kit.standRefuses("открыть адрес в браузере") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Открывает адрес входа в браузере по умолчанию, но только тот, что пришёл после просьбы: прежний код уже мог быть использован.
@MainActor
final class StudioBrowserHandoff {
    private var after: Int?
    /// Номер кода, открытого в браузере.
    private(set) var claimed = 0
    private let open: @MainActor (URL) -> Void

    init(open: @escaping @MainActor (URL) -> Void) { self.open = open }

    func request(after login: Int) { after = login }

    func observe(_ state: StudioState) {
        guard let after, state.login > after, state.phase == .running, let target = StudioNavigation.loginURL(state.page) else { return }
        self.after = nil
        claimed = state.login
        open(target.url)
    }
}

/// Когда странице нужен новый код входа. Код одноразовый, а адрес в состоянии остаётся прежним, пока его не сменят:
/// страница, созданная заново, не должна открывать уже использованный.
struct StudioLoginGate: Equatable {
    enum Step: Equatable {
        case wait
        /// Попросить у утилиты новый код: прежний мог быть потрачен до создания этой страницы.
        case requestNew
        case load(URL, login: Int)
    }

    private(set) var loaded = 0
    private var baseline: Int?

    /// `claimed` — номер кода, который открыт в браузере: эту страницу он не для окна.
    mutating func step(_ state: StudioState, skipping claimed: Int = 0) -> Step {
        guard state.phase == .running, let target = StudioNavigation.loginURL(state.page) else { return .wait }
        if loaded > 0 {
            guard state.login > loaded else { return .wait }
            if state.login == claimed {
                loaded = state.login
                return .wait
            }
        } else {
            guard let baseline else {
                self.baseline = state.login
                return .requestNew
            }
            guard state.login > baseline else { return .wait }
            if state.login == claimed {
                self.baseline = state.login
                return .requestNew
            }
        }
        loaded = state.login
        return .load(target.url, login: state.login)
    }

    /// Сервер остановился или упал: следующая страница начнёт заново.
    mutating func reset() {
        loaded = 0
        baseline = nil
    }
}
