import AppKit
import SwiftUI
import WebKit

/// Страница Студии внутри окна. Ходить ей можно только на `http://127.0.0.1:<порт>` и `localhost:<порт>` своего порта;
/// чужие `http` и `https` открываются в браузере по умолчанию, остальные схемы (`file`, `javascript`, `data`…) не открываются нигде.
/// Хранилище одноразовое: после закрытия окна от входа ничего не остаётся на диске.
@MainActor
final class StudioWebHolder: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// Порт страницы, на который можно ходить; 0 — пока ничего не загружено, и не разрешено ничего.
    var port = 0
    private var gate = StudioLoginGate()
    private let openExternal: @MainActor (URL) -> Void

    init(openExternal: @escaping @MainActor (URL) -> Void = { StudioOpen.inBrowser($0) }) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.openExternal = openExternal
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
    }

    /// Состояние изменилось: загрузить адрес входа, если он новый, или попросить новый код.
    func update(_ model: some StudioModel) {
        let state = model.state
        if state.phase != .running {
            gate.reset()
            return
        }
        switch gate.step(state, skipping: model.browserLogin) {
        case .wait: break
        case .requestNew: model.newLogin()
        case .load(let url, _):
            guard let target = StudioNavigation.loginURL(url.absoluteString) else { return }
            port = target.port
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let clicked = navigationAction.navigationType == .linkActivated
        Task { @MainActor in decisionHandler(self.route(url, mainFrame: mainFrame, linkClicked: clicked)) }
    }

    /// Единственное место решения: переход, ссылка из страницы и новое окно идут через него. Чужой адрес уходит в браузер
    /// только по клику на ссылку в основном окне: встроенный фрейм или скрипт без клика не могут открывать вкладки сами.
    func route(_ url: URL?, mainFrame: Bool = true, linkClicked: Bool = true) -> WKNavigationActionPolicy {
        switch StudioNavigation.decide(url, port: port) {
        case .allow: return .allow
        case .openInBrowser:
            if let url, mainFrame, linkClicked { openExternal(url) }
            return .cancel
        case .refuse: return .cancel
        }
    }

    // MARK: WKUIDelegate

    /// Новое окно страница получить не может: адрес идёт по тем же правилам, и окно не создаётся.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let clicked = navigationAction.navigationType == .linkActivated
        Task { @MainActor in _ = self.route(url, mainFrame: true, linkClicked: clicked) }
        return nil
    }
}

struct StudioWebView: NSViewRepresentable {
    let holder: StudioWebHolder

    func makeNSView(context: Context) -> WKWebView { holder.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
