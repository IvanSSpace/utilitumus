import SwiftUI
import AppKit

/// Цвет шапки по значку программы: считается один раз на bundle id и только здесь, на этом Mac.
@MainActor
enum ClipSourceTint {
    private static var cache: [String: ClipRGB] = [:]

    static func color(_ bundleID: String?) -> ClipRGB {
        guard let bundleID else { return ClipHeaderTint.neutral }
        if let hit = cache[bundleID] { return hit }
        let tint = ClipSourceIcon.largeImage(bundleID).flatMap(pixels).map(ClipHeaderTint.dominant) ?? ClipHeaderTint.neutral
        cache[bundleID] = tint
        return tint
    }

    /// Значок в 32×32 в sRGB, альфа снята.
    static func pixels(_ image: NSImage) -> [UInt8]? {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let raw = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: out.count, by: 4) {
            let alpha = Double(raw[i + 3])
            out[i + 3] = raw[i + 3]
            guard alpha > 0 else { continue }
            for channel in 0..<3 { out[i + channel] = UInt8(min(255, Double(raw[i + channel]) * 255 / alpha)) }
        }
        return out
    }
}

extension ClipRGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

struct ClipCard: View {
    let item: ClipItem
    let number: Int?
    let selected: Bool
    let searching: Bool
    let theme: DSTheme
    /// Отдельно от модели: карточка без своей подписки на модель не перерисовывается при каждом нажатии.
    let spaces: [ClipSpace]
    let now: Date
    let model: ClipboardPanelModel

    static let width = ClipboardPreview.cardWidth
    static let height = ClipPanelMetrics.cardHeight
    static let headerHeight: CGFloat = 54
    private static let radius: CGFloat = 16

    private var tint: Color { Self.headerColor(item, theme: theme).color }

    /// Шапка чёрно-серая в «Графите», в остальных темах из значка программы.
    @MainActor static func headerColor(_ item: ClipItem, theme: DSTheme) -> ClipRGB {
        theme == .graphite ? ClipHeaderTint.graphite : ClipSourceTint.color(item.sourceBundleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color(white: 0.085))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            if selected {
                // Рамка снаружи карточки: так шапка и значок не меняются при выборе.
                RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                    .stroke(searching ? Color(white: 0.55) : theme.accent(.clipboard), lineWidth: 4)
                    .padding(-3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .contextMenu { menu }
    }

    // MARK: Шапка

    private var header: some View {
        ZStack(alignment: .leading) {
            tint
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                sourceIcon
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.kind.title).font(.system(size: 15, weight: .semibold))
                    if let space = spaces.first(where: { $0.id == item.spaceID }) {
                        Circle().fill(ClipPalette.color(space.colorID)).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                            .help("Пространство «\(space.name)»")
                    }
                }
                Text(ClipPanelText.ago(item.date, now: now)).font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .padding(.leading, ClipboardPreview.textInset)
            .padding(.trailing, 62)
            .lineLimit(1)
        }
        .frame(height: Self.headerHeight)
        .clipped()
    }

    /// Значок заходит за правый верхний угол: края срезает скругление карточки.
    @ViewBuilder private var sourceIcon: some View {
        if let icon = ClipSourceIcon.largeImage(item.sourceBundleID) {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: 78, height: 78)
                .offset(x: 12, y: -4)
                .frame(width: 62, height: Self.headerHeight, alignment: .leading)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
                .padding(.trailing, 14)
        }
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(ClipboardPreview.shownText(item.text ?? ""))
                .font(.system(size: ClipboardPreview.fontSize)).foregroundStyle(.white.opacity(0.92))
                .lineLimit(ClipboardPreview.maxLines).multilineTextAlignment(.leading)
                .frame(width: ClipboardPreview.textWidth, alignment: .topLeading)
                .padding(.horizontal, ClipboardPreview.textInset).padding(.top, 12)
        case .link:
            // Только то, что есть на этом Mac: страницу не запрашиваем, сайт не должен узнать, что скопировано.
            ZStack {
                tint.opacity(0.72)
                if let icon = ClipSourceIcon.largeImage(item.sourceBundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 76, height: 76)
                } else {
                    Image(systemName: "link").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let image = model.image(item) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: Self.width, height: Self.height - Self.headerHeight - Self.footerHeight)
                    .clipped()
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array((item.filePaths ?? []).prefix(6)), id: \.self) { path in
                    HStack(spacing: 7) {
                        Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        Text((path as NSString).lastPathComponent).font(.system(size: ClipboardPreview.fontSize))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
            }
            .padding(.horizontal, ClipboardPreview.textInset).padding(.top, 12)
        }
    }

    // MARK: Низ

    private static let footerHeight: CGFloat = 34
    private static let linkFooterHeight: CGFloat = 54

    @ViewBuilder private var footer: some View {
        if item.kind == .link {
            linkFooter
        } else {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(caption).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                numberLabel
            }
            .padding(.horizontal, ClipboardPreview.textInset)
            .frame(height: Self.footerHeight)
        }
    }

    private var linkFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Text(linkTitle).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text(item.text ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                numberLabel
            }
        }
        .padding(.horizontal, ClipboardPreview.textInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.linkFooterHeight)
        .background(Color(white: 0.19))
    }

    /// Заголовка страницы нет: её не запрашиваем. Вместо него сайт, у почты адрес без `mailto:`.
    private var linkTitle: String {
        let text = item.text ?? ""
        return item.host ?? (text.hasPrefix("mailto:") ? String(text.dropFirst(7)) : text)
    }

    @ViewBuilder private var numberLabel: some View {
        if let number {
            Text("⌘\(number)").font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
        }
    }

    private var caption: String {
        switch item.kind {
        case .text: return ClipboardPreview.caption(for: item.text ?? "")
        case .link: return item.host ?? "ссылка"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight { return "\(w)×\(h)" }
            return "картинка"
        case .file:
            let n = item.filePaths?.count ?? 0
            return "\(n) \(ClipboardPreview.word(n, "файл", "файла", "файлов"))"
        }
    }

    // MARK: Меню

    @ViewBuilder private var menu: some View {
        Button("Вставить") { model.onPaste(item) }
        Menu("В пространство") {
            ForEach(spaces) { space in
                Button(space.name) { model.onPin(item.id, space.id) }
            }
            if spaces.isEmpty { Text("Пространств нет — создай кнопкой + вверху") }
        }
        if item.spaceID != nil {
            Button("Убрать из пространства") { model.onPin(item.id, nil) }
        }
        Divider()
        Button("Удалить", role: .destructive) { model.onDelete(item.id) }
    }
}
