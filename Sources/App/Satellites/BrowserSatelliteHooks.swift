import Foundation

extension SatelliteHooks {
    /// «Браузер»: вложенный помощник ссылок регистрируется после установки, запущенный старый останавливается перед
    /// заменой, а перед удалением браузер по умолчанию возвращается, если других копий помощника нет.
    /// `afterInstall` только регистрирует: обработчиком по умолчанию установщик не назначает никогда.
    static func browser(_ handler: BrowserLinkHandler) -> SatelliteHooks {
        SatelliteHooks(
            afterInstall: { handler.register($0.appendingPathComponent("Contents/Helpers/\(BrowserHelper.helperName)")) },
            beforeReplace: { handler.services.stopHelpers($0) },
            beforeRemove: { try await handler.release(removing: $0) },
            afterQuit: { handler.services.stopHelpers($0) })
    }
}
