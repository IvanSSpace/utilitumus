import AppKit

/// Чтение и запись NSPasteboard. Отдельно от контроллера, чтобы проверять на своём именованном буфере.
enum ClipboardPasteboard {
    /// Снимок текущего содержимого. Скрытые типы попадают в `types`, дальше их отсеивает политика.
    static func snapshot(of pasteboard: NSPasteboard) -> ClipSnapshot {
        var snap = ClipSnapshot()
        snap.types = (pasteboard.types ?? []).map(\.rawValue)
        if ClipboardPolicy.shouldSkip(types: snap.types) { return snap }

        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        snap.filePaths = fileURLs.map(\.path)
        snap.text = pasteboard.string(forType: .string)
        if snap.filePaths.isEmpty, snap.text?.isEmpty != false {
            snap.imagePNG = pngData(from: pasteboard)
        }
        return snap
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Кладёт запись в буфер. Возвращает changeCount после записи — контроллер по нему узнаёт «своё».
    @discardableResult
    static func write(_ item: ClipItem, imageData: Data?, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if let imageData { pasteboard.setData(imageData, forType: .png) }
        case .file:
            pasteboard.writeObjects((item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        return pasteboard.changeCount
    }
}
