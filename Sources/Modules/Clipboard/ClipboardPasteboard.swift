import AppKit
import ImageIO

/// Чтение и запись NSPasteboard. Отдельно от контроллера, чтобы проверять на своём именованном буфере.
enum ClipboardPasteboard {
    /// Снимок для опроса, вызывается вне главного потока. nil — буфер поменялся до конца чтения:
    /// содержимое уже другое, его прочитает следующий опрос.
    static func snapshot(of pasteboard: NSPasteboard, change: Int) -> ClipSnapshot? {
        guard pasteboard.changeCount == change else { return nil }
        let snap = snapshot(of: pasteboard)
        return pasteboard.changeCount == change ? snap : nil
    }

    /// Снимок текущего содержимого. Скрытые типы попадают в `types`, дальше их отсеивает политика.
    static func snapshot(of pasteboard: NSPasteboard) -> ClipSnapshot {
        var snap = ClipSnapshot()
        snap.types = (pasteboard.types ?? []).map(\.rawValue)
        if ClipboardPolicy.shouldSkip(types: snap.types) { return snap }

        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        snap.filePaths = fileURLs.map(\.path)
        snap.text = pasteboard.string(forType: .string).map(ClipboardPolicy.trimmedText)
        if snap.filePaths.isEmpty, snap.text?.isEmpty != false {
            snap.imagePNG = pngData(from: pasteboard)
        }
        return snap
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png.count <= ClipboardPolicy.maxImageBytes ? png : nil }
        guard let tiff = pasteboard.data(forType: .tiff), tiffFits(tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Размер читается из заголовка, без декодирования: маленький файл может распаковаться в гигабайты.
    private static func tiffFits(_ tiff: Data) -> Bool {
        guard tiff.count <= ClipboardPolicy.maxTIFFBytes,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return ClipboardPolicy.tiffFits(bytes: tiff.count, width: width, height: height)
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
