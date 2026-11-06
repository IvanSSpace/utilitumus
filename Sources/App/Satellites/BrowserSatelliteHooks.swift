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

/// Отказ удалить «Буфер»: ключ истории не удалось вернуть центру.
struct ClipboardKeyReturnError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SatelliteHooks {
    /// «Буфер»: перед удалением утилита возвращает ключ истории центру, иначе встроенный модуль не смог бы открыть
    /// историю. Нет ответа и передачи не было — удалять можно, ключ и так у центра.
    static func clipboard(
        keyring: ClipboardKeyring,
        directory: URL = ClipboardStore.defaultDirectory,
        handedOver: @escaping @Sendable () -> Bool,
        send: @escaping @Sendable (Data) async throws -> Data
    ) -> SatelliteHooks {
        SatelliteHooks(beforeRemove: { _ in
            let result = await ClipboardKeyReturn(keyring: keyring, directory: directory, send: send).run()
            switch result {
            case .done, .nothingToReturn: return
            case .unreachable:
                guard handedOver() else { return }
                throw ClipboardKeyReturnError(message: "Утилита «Буфер» не отвечает, а ключ истории у неё. Запусти её и повтори: иначе история станет нечитаемой")
            case .failed(let reason):
                throw ClipboardKeyReturnError(message: "Не удалось вернуть ключ истории из утилиты, модуль не удалён: \(reason)")
            }
        })
    }
}
