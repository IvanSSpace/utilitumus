import AppKit

/// Что карточка панели показывает из текста и что остаётся за её краем. Вставляется текст целиком,
/// поэтому о невидимой части нужно сказать: страница может спрятать команду ниже безобидной первой строки.
enum ClipboardPreview {
    static let maxCharacters = 400
    static let maxLines = 9
    static let fontSize: CGFloat = 13
    static let cardWidth: CGFloat = 242
    static let textInset: CGFloat = 14
    static let textWidth: CGFloat = cardWidth - textInset * 2

    static func shownText(_ text: String) -> String { String(text.prefix(maxCharacters)) }

    /// Сколько строк текста не видно. Строки считаются по переводам строки: так их увидит программа, куда вставляем.
    /// Что влезло, считает та же раскладка текста: перенос длинных строк по одним символам не угадать.
    static func hiddenLines(in text: String) -> Int {
        let storage = NSTextStorage(string: shownText(text), attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let shown = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length
        let rest = text[text.utf16.index(text.utf16.startIndex, offsetBy: shown)...]
        guard !rest.isEmpty else { return 0 }
        let lines = rest.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return rest.last?.isNewline == true ? lines - 1 : lines
    }

    /// Склонение по числу: 1 минуту, 4 минуты, 8 минут, 21 минуту, 11 минут.
    static func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        switch (n % 10, n % 100) {
        case (1, let h) where h != 11: return one
        case (2...4, let h) where !(12...14).contains(h): return few
        default: return many
        }
    }

    static func hiddenCaption(_ lines: Int) -> String {
        "ещё \(lines) \(word(lines, "строка", "строки", "строк"))"
    }

    /// Подпись карточки: число символов и то, что не видно.
    static func caption(for text: String) -> String {
        let count = "\(text.count) \(word(text.count, "символ", "символа", "символов"))"
        let hidden = hiddenLines(in: text)
        return hidden > 0 ? "\(count) · \(hiddenCaption(hidden))" : count
    }
}
