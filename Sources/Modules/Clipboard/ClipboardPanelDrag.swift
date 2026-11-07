import Foundation
import UniformTypeIdentifiers

/// Что несёт перетаскивание карточки. Наружу настоящее содержимое, внутрь панели свой тип с номером записи.
/// Системный буфер здесь не участвует: у перетаскивания свой буфер, поэтому истории и нового снимка не будет.
enum ClipDrag {
    /// Свой тип для броска на категорию. Динамический по расширению: объявленный идентификатор без записи в Info.plist
    /// SwiftUI при броске прочитать не может («Failed to instantiate a content type»), а этому объявление не нужно.
    static let recordType = UTType(filenameExtension: "utilitumus-clip-record", conformingTo: .data)!
    /// Перенос категории: отдельный тип, запись на его месте не примут и наоборот.
    static let spaceType = UTType(filenameExtension: "utilitumus-clip-space", conformingTo: .data)!

    /// Картинка отдаётся байт в байт и только когда программа попросила: `loadImage` до этого не зовётся.
    static func provider(for item: ClipItem, loadImage: @escaping @Sendable () -> Data?,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> NSItemProvider {
        let provider = NSItemProvider()
        switch item.kind {
        case .text:
            if let text = item.text { registerString(text, on: provider) }
        case .link:
            guard let text = item.text else { break }
            registerString(text, on: provider)
            // Адрес тоже, только если он прошёл ту же проверку, что при записи: `javascript:` и подобное остаётся текстом.
            if ClipboardPolicy.isLink(text), let url = URL(string: text) { provider.registerObject(url as NSURL, visibility: .all) }
        case .image:
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
                if let data = loadImage() { done(data, nil) } else { done(nil, CocoaError(.fileReadNoSuchFile)) }
                return nil
            }
        case .file:
            // В одном провайдере один файловый адрес, а `onDrag` даёт один провайдер: из нескольких файлов уходит первый живой.
            if let path = item.filePaths?.first(where: fileExists) {
                provider.registerObject(URL(fileURLWithPath: path) as NSURL, visibility: .all)
            }
        }
        // Номер записи: сырые 16 байт под своим типом, программа, вставляющая текст, его не увидит.
        let id = data(for: item.id)
        provider.registerDataRepresentation(forTypeIdentifier: recordType.identifier, visibility: .all) { done in
            done(id, nil)
            return nil
        }
        return provider
    }

    /// Категория: только номер под своим типом. Другим программам взять нечего.
    static func spaceProvider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let bytes = data(for: id)
        provider.registerDataRepresentation(forTypeIdentifier: spaceType.identifier, visibility: .all) { done in
            done(bytes, nil)
            return nil
        }
        return provider
    }

    /// Только простой текст. `registerObject(NSString)` объявил бы и URL, а на проверку адреса выше полагается бросок ссылки.
    private static func registerString(_ text: String, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { done in
            done(Data(text.utf8), nil)
            return nil
        }
    }

    static func data(for id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }

    static func recordID(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Бросок на категорию: только провайдер со своим типом. Посторонний текст сюда не проходит.
    static func recordProvider(in providers: [NSItemProvider]) -> NSItemProvider? {
        providers.first { $0.hasItemConformingToTypeIdentifier(recordType.identifier) }
    }
}
