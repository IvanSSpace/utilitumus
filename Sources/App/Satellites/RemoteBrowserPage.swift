import SwiftUI

/// Вкладка «Браузер», когда его ведёт утилита. Экран читает общий домен настроек
/// сам, утилита ему не нужна, поэтому модели связи нет. От утилиты — только «не отвечает» и «выключен».
struct RemoteBrowserPage: View {
    @ObservedObject private var registry = SatelliteRegistry.shared
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        let status = registry.entries[.browser]?.status
        if status == nil {
            SatellitePage(module: .browser)
        } else if status?.enabled == false {
            ModuleOffView(module: .browser) { registry.setEnabled(.browser, true) } more: { modules.infoModule = .browser }
        } else {
            ModuleScreen(module: .browser) { BrowserView() }
        }
    }
}

/// Утилиту «Браузер» убрали мимо центра (Корзина, `rm`), а ссылки открывал её помощник: копий нет, обработчик
/// назначен впустую, ссылки не открываются нигде. Узнать это можно только по своей метке (`BrowserLinkHandler.markerKey`).
@MainActor
enum BrowserOrphanOffer {
    static func present(_ links: BrowserLinkHandler) {
        guard let target = links.orphanOffer() else { return }
        let name = FileManager.default.displayName(atPath: target.url.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Ссылки больше некому открывать"
        alert.informativeText = "Модуль «Браузер» удалён не из Utilitumus, и ссылки остались за ним. Вернуть браузер по умолчанию: \(name)? macOS попросит подтвердить."
        alert.addButton(withTitle: "Вернуть \(name)")
        alert.addButton(withTitle: "Не сейчас")
        // Не блокировать запуск: окно приходит после того, как центр показался.
        DispatchQueue.main.async {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await links.restoreOrphaned()
                } catch {
                    let failure = NSAlert(error: error)
                    failure.runModal()
                }
            }
        }
    }
}
