import AppKit
import Foundation

/// Выдуманные записи и категории для проверки и показа панели. Настоящей истории здесь нет.
enum ClipPanelFixture {
    static let work = ClipSpace(id: UUID(), name: "работа", colorID: "red")
    static let code = ClipSpace(id: UUID(), name: "code", colorID: "orange")
    static let long = ClipSpace(id: UUID(), name: "очень длинное название пространства, которое не влезет в кнопку целиком", colorID: "purple")
    static let spaces = [work, code, ClipSpace(id: UUID(), name: "гайды", colorID: "green"), long,
                         ClipSpace(id: UUID(), name: "minecraft", colorID: "yellow"),
                         ClipSpace(id: UUID(), name: "дом", colorID: "teal")]

    static func entry(_ kind: ClipKind, _ text: String?, source: String?, ago seconds: TimeInterval, now: Date,
                      paths: [String]? = nil, size: (Int, Int)? = nil, space: UUID? = nil) -> ClipItem {
        ClipItem(id: UUID(), hash: UUID().uuidString, kind: kind, text: text, filePaths: paths,
                 imageFile: kind == .image ? "fixture.bin" : nil, imageWidth: size?.0, imageHeight: size?.1,
                 sourceBundleID: source, sourceName: source, date: now.addingTimeInterval(-seconds), spaceID: space)
    }

    static func items(now: Date = Date()) -> [ClipItem] {
        let longText = (1...24).map { "Строка \($0) выдуманного текста, который не помещается на карточке" }.joined(separator: "\n")
        return [
            entry(.link, "https://example.com/invite/ABCDEF123456?source=clipboard&campaign=very-long-tracking-value-that-does-not-fit-at-all",
                  source: "com.google.Chrome", ago: 4 * 60, now: now),
            entry(.text, "Нет общего состояния, агенты не мешают друг другу. Минус: в чистом дереве нет настроек, агент будет спрашивать разрешения, решим копированием при создании.",
                  source: "com.microsoft.VSCode", ago: 8 * 60, now: now, space: work.id),
            entry(.image, nil, source: "com.apple.Preview", ago: 31, now: now, size: (1600, 900)),
            entry(.file, nil, source: "com.apple.finder", ago: 22 * 60, now: now,
                  paths: ["/tmp/Отчёт за ноябрь.pdf", "/tmp/Смета.xlsx", "/tmp/Очень длинное название файла, которое обязательно обрежется посередине строки.txt"]),
            entry(.text, longText, source: "com.apple.Terminal", ago: 2 * 3600, now: now),
            entry(.text, "m.docker.socket:", source: nil, ago: 3 * 86400, now: now),
            entry(.text, "Жёлтый значок заметок не должен сделать шапку светлой.", source: "com.apple.Notes", ago: 90 * 60, now: now),
            entry(.link, "mailto:someone@example.com", source: nil, ago: 26 * 3600, now: now, space: code.id),
            entry(.text, "Девятая карточка", source: "com.apple.Safari", ago: 5 * 86400, now: now),
            entry(.text, "Десятая карточка, у неё уже нет ⌘-номера", source: "com.apple.TextEdit", ago: 6 * 86400, now: now),
        ]
    }

    /// Нарисованная картинка вместо расшифрованной из хранилища.
    static func image(_ item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        let image = NSImage(size: NSSize(width: 800, height: 450))
        image.lockFocus()
        NSGradient(starting: NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.3, alpha: 1),
                   ending: NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 800, height: 450), angle: 35)
        image.unlockFocus()
        return image
    }
}
