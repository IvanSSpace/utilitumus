import SwiftUI

/// Маленький markdown дела: заголовки, списки (в том числе `[x]`), абзацы, `код` и **жирный**. Как у страницы Студии (app.js).
/// Ссылок и картинок нет вовсе: дело пишет мастер, его текст — данные, а не разметка. Живая ссылка в деле была бы кликабельной.
enum StudioMarkdown {
    enum Block: Equatable {
        case heading(String)
        case bullet(String, done: Bool?)
        case paragraph(String)
    }

    enum Span: Equatable {
        case plain(String)
        case code(String)
        case bold(String)
    }

    /// Заголовок первого уровня пропускается: название дела уже в шапке панели.
    static func blocks(_ source: String) -> [Block] {
        var out: [Block] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
            if line.isEmpty { continue }
            if line.hasPrefix("# ") { continue }
            if let heading = headingText(line) {
                out.append(.heading(heading))
                continue
            }
            if let bullet = bulletParts(String(raw)) {
                out.append(.bullet(bullet.text, done: bullet.done))
                continue
            }
            out.append(.paragraph(line))
        }
        return out
    }

    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (2...4).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
    }

    private static func bulletParts(_ raw: String) -> (text: String, done: Bool?)? {
        var line = Substring(raw.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r"))))
        guard let first = line.first, first == "-" || first == "*", line.dropFirst().first == " " else { return nil }
        line = line.dropFirst(2)
        var done: Bool?
        for (mark, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where line.hasPrefix(mark) {
            done = value
            line = line.dropFirst(mark.count)
        }
        return (String(line).trimmingCharacters(in: .whitespaces), done)
    }

    /// `код` и **жирный**; всё остальное — обычный текст как есть.
    static func spans(_ text: String) -> [Span] {
        var out: [Span] = []
        var plain = ""
        var rest = Substring(text)
        func flush() { if !plain.isEmpty { out.append(.plain(plain)); plain = "" } }
        while let c = rest.first {
            if c == "`", let end = rest.dropFirst().firstIndex(of: "`"), end > rest.index(after: rest.startIndex) {
                flush()
                out.append(.code(String(rest[rest.index(after: rest.startIndex)..<end])))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                flush()
                out.append(.bold(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])))
                rest = rest[end.upperBound...]
            } else {
                plain.append(c)
                rest = rest.dropFirst()
            }
        }
        flush()
        return out
    }

    /// Текст из кусков: код моноширинным, жирный жирным. `AttributedString(_: String)` не разбирает markdown, ссылки не оживают.
    static func attributed(_ source: String) -> AttributedString {
        var out = AttributedString()
        for span in spans(source) {
            switch span {
            case .plain(let t):
                out += AttributedString(t)
            case .code(let t):
                var run = AttributedString(t)
                run.font = .system(size: 11.5, design: .monospaced)
                run.foregroundColor = .white.opacity(0.85)
                out += run
            case .bold(let t):
                var run = AttributedString(t)
                run.inlinePresentationIntent = .stronglyEmphasized
                out += run
            }
        }
        return out
    }
}

/// Дело блоками. Длинное прокручивается в панели, а не растягивает страницу.
struct StudioCaseView: View {
    let text: String

    var body: some View {
        let blocks = StudioMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(StudioMarkdown.attributed(t)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.top, 5)
                case .bullet(let t, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done == nil ? "circle.fill" : (done == true ? "checkmark.circle.fill" : "circle"))
                            .font(.system(size: done == nil ? 4 : 10)).foregroundStyle(.white.opacity(0.4))
                            .frame(width: 12)
                        Text(StudioMarkdown.attributed(t)).font(.system(size: 12)).foregroundStyle(.white.opacity(done == true ? 0.4 : 0.78))
                            .strikethrough(done == true)
                    }
                case .paragraph(let t):
                    Text(StudioMarkdown.attributed(t)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
