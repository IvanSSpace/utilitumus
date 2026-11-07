import AppKit
import ImageIO
import UniformTypeIdentifiers

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
        // Настоящий текст с картинкой рядом (Word, Excel) остаётся текстом: картинку здесь даже не читаем.
        if snap.filePaths.isEmpty, ClipboardStore.imageOutranks(text: snap.text) {
            snap.imagePNG = pngData(from: pasteboard)
        }
        return snap
    }

    /// nil и у картинки сверх предела: запись тогда остаётся ссылкой, если адрес был рядом, а не пропадает.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png.count <= ClipboardPolicy.maxImageBytes ? png : nil }
        // TIFF система достраивает из любого формата и разжимает прямо при чтении `.tiff`, поэтому исходный файл
        // проверяется раньше: JPEG меньше мегабайта может развернуться в сотни мегабайт.
        let declared = pasteboard.pasteboardItems?.first?.types ?? []
        if !declared.contains(.tiff) {
            for type in declared where UTType(type.rawValue)?.conforms(to: .image) == true {
                guard let source = pasteboard.data(forType: type), imageFits(source) else { return nil }
            }
        }
        guard let tiff = pasteboard.data(forType: .tiff), imageFits(tiff), let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.count <= ClipboardPolicy.maxImageBytes ? png : nil
    }

    /// Размер читается из заголовка, без декодирования: маленький файл может распаковаться в гигабайты.
    private static func imageFits(_ data: Data) -> Bool {
        guard data.count <= ClipboardPolicy.maxTIFFBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return ClipboardPolicy.tiffFits(bytes: data.count, width: width, height: height)
    }

    /// Кладёт запись в буфер. Возвращает changeCount после записи — контроллер по нему узнаёт «своё».
    @discardableResult
    static func write(_ item: ClipItem, imageData: Data?, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            // Только PNG, те же байты. `.tiff` потребителю достраивает система в его процессе (см. Tests/ClipboardCheck.swift, раздел 12).
            if let imageData { pasteboard.setData(imageData, forType: .png) }
        case .file:
            pasteboard.writeObjects((item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        return pasteboard.changeCount
    }
}
