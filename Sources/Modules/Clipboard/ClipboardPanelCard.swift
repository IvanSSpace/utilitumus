import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

/// Системный значок типа файла по расширению: сам файл не открывается. Один на расширение за процесс.
@MainActor
enum ClipFileTypeIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        if let hit = cache[ext] { return hit }
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        cache[ext] = icon
        return icon
    }
}

/// Миниатюра, разжатая вне главного потока сразу в цвета и порядок байт экрана: вывод кадра её только копирует.
/// Из `NSImage(data:)` цвета переводились бы при выводе кадра, на главном потоке.
struct ClipScreenPicture: @unchecked Sendable {
    /// Пространство цвета экрана: берётся на главном потоке, неизменяемо, передаётся на очередь разжатия.
    struct Space: @unchecked Sendable { let value: CGColorSpace? }

    let image: CGImage
    let size: NSSize

    /// nil — не картинка или больше предела стороны миниатюры: свою миниатюру больше сделать нельзя.
    init?(_ data: Data, space: Space) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width <= ClipThumbnail.maxSide, decoded.height <= ClipThumbnail.maxSide,
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space.value ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = context.makeImage() else { return nil }
        self.image = image
        size = NSSize(width: CGFloat(decoded.width) / 2, height: CGFloat(decoded.height) / 2)
    }
}

/// Картинка карточки файла. Разжимается вне главного потока, когда панель доехала; до того на её месте фон карточки,
/// первые кадры панели её не ждут. Перерисовывается по своему счётчику: у карточки подписки на модель нет.
/// Миниатюра не прочиталась — крупный значок типа по расширению, тоже без чтения файла.
private struct ClipFilePicture: View {
    let item: ClipItem
    /// Путь показанного файла: по нему значок типа, если миниатюры не будет.
    let shown: String
    /// Показ панели: в новом показе загрузка заново, кэш прошлого уже забыт.
    let shownAt: Date
    let model: ClipboardPanelModel
    /// Сколько раз миниатюра легла в кэш: смена счётчика перерисовывает только этот вид.
    @State private var arrivals = 0
    @State private var failed = false

    private struct Key: Equatable {
        let id: UUID
        let shownAt: Date
        /// Кэш мог отпустить миниатюру, пока карточка жива: тогда загрузка ещё раз.
        let ready: Bool
    }

    var body: some View {
        let _ = arrivals
        let image = model.readyPicture(item)
        ZStack {
            if let image {
                // Без перехода: проявление при каждом показе сначала гасило бы прошлую миниатюру, +9 мс к повторному
                // открытию (замер bench47-after2). Целиком, вписанной по центру: края не срезаются.
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed, let icon = ClipFileTypeIcon.image(shown) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 64, height: 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Key(id: item.id, shownAt: shownAt, ready: image != nil)) {
            guard image == nil else { return }
            if await model.loadFilePicture(item) {
                arrivals += 1
            } else if model.picturesAllowed {
                // Отказ из-за ушедшей панели или прогрева — не отказ миниатюры: значок не нужен.
                failed = true
            }
        }
    }
}

/// Что вышло у кнопок «Показать превью»: по записи, только в памяти панели. Свой объект, а не поле модели: следят за ним
/// только карточки с кнопкой, остальные от него не перерисовываются.
@MainActor
final class ClipFilePreviews: ObservableObject {
    enum State: Equatable {
        /// Идёт чтение: кнопка неактивна.
        case reading
        /// macOS не дала доступа: кнопка и подсказка про Настройки.
        case denied
        /// Не «нет доступа»: файла нет, не картинка, больше предела, только в iCloud. Без кнопки, значок типа.
        case failed
    }

    @Published var states: [UUID: State] = [:]

    func finish(_ id: UUID, _ result: ClipFileResult) {
        switch result {
        // Миниатюра записана: запись теперь с ней, карточка покажет её. Хранилища не было — снова кнопка.
        case .made, .needsAccess: states[id] = nil
        case .denied: states[id] = .denied
        case .unavailable: states[id] = .failed
        }
    }
}

/// Файл-картинка в «спрашиваемой» папке без доступа: значок типа по расширению, кнопка «Показать превью» и строка о том,
/// что будет. Файл до нажатия не читается. Кнопка своя: клик по ней не выбирает и не вставляет карточку.
struct ClipFileAsk: View {
    let item: ClipItem
    let folder: ClipAskFolder
    let shown: String
    let model: ClipboardPanelModel
    @ObservedObject var previews: ClipFilePreviews

    static let askText = "Показать превью"
    static let deniedText = "нет доступа: Настройки → Конфиденциальность → Файлы и папки"
    static func hint(_ folder: ClipAskFolder) -> String { "macOS один раз спросит доступ к папке «\(folder.title)»" }

    var body: some View {
        let state = previews.states[item.id]
        VStack(spacing: 7) {
            if let icon = ClipFileTypeIcon.image(shown) {
                let side: CGFloat = state == .failed ? 64 : 36
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
            }
            if state != .failed {
                Button { model.requestFilePreview(item) } label: {
                    Text(Self.askText).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(state == .reading ? 0.08 : 0.18)))
                        .contentShape(Capsule())
                }
                // Как у кнопок панели: без системной рамки и без клавиатурного фокуса.
                .buttonStyle(.plain).focusable(false)
                .disabled(state == .reading)
                Text(state == .denied ? Self.deniedText : Self.hint(folder))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
    /// Вместо содержимого точки. Отдельно от модели, как и `spaces`: иначе карточка не перерисуется, когда скрытие сменится.
    let concealed: Bool
    var editingTitle = false
    /// Сколько выбрано вместе с этой карточкой; 0 — она не в группе. Меню тогда про всех.
    var groupCount = 0
    /// Плавающая копия при перетаскивании: только сама карточка, без рамки выбора и без меню.
    var isDragPreview = false

    static let width = ClipboardPreview.cardWidth
    static let height = ClipPanelMetrics.cardHeight
    static let headerHeight: CGFloat = 52
    private static let radius: CGFloat = 16

    private var tint: Color { Self.headerColor(item, theme: theme).color }

    /// Шапка чёрно-серая в «Графите», в остальных темах из значка программы.
    @MainActor static func headerColor(_ item: ClipItem, theme: DSTheme) -> ClipRGB {
        theme == .graphite ? ClipHeaderTint.graphite : ClipSourceTint.color(item.sourceBundleID)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    private var face: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color(white: 0.085))
        .clipShape(shape)
    }

    @ViewBuilder var body: some View {
        if isDragPreview { face } else { interactive }
    }

    private var interactive: some View {
        face
        .overlay {
            if selected {
                // Рамка снаружи карточки: так шапка и значок не меняются при выборе.
                RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                    .stroke(searching ? Color(white: 0.55) : theme.accent(.clipboard), lineWidth: 4)
                    .padding(-3)
            }
        }
        .contentShape(shape)
        .contentShape(.dragPreview, shape)
        // Копия рисуется отдельно: со снимком всей карточки в неё попадали куски рамки выбора, выходящей за края.
        .onDrag {
            model.dragProvider(for: item)
        } preview: {
            ClipCard(item: item, number: number, selected: false, searching: false, theme: theme, spaces: spaces, now: now,
                     model: model, concealed: ClipConcealment.isHidden(item, in: spaces), isDragPreview: true)
        }
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
                    titleLine
                    if let space = spaces.first(where: { $0.id == item.spaceID }) {
                        Circle().fill(ClipPalette.color(space.colorID)).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                            .help("Пространство «\(space.name)»")
                            .transition(.opacity)
                    }
                }
                Text(subtitle).font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .padding(.leading, ClipboardPreview.textInset)
            .padding(.trailing, 58)
            .lineLimit(1)
        }
        .frame(height: Self.headerHeight)
        .clipped()
    }

    @ViewBuilder private var titleLine: some View {
        if editingTitle {
            ClipInlineField(placeholder: "Название", font: .system(size: 15, weight: .semibold),
                            text: Binding(get: { model.titleEdit?.text ?? "" }, set: { model.titleEdit?.text = $0 }))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.28)))
                .padding(.horizontal, -4)
        } else {
            // Попасть можно только в сам текст: двойной клик по остальной шапке по-прежнему вставляет.
            Text(item.title ?? item.kind.title).font(.system(size: 15, weight: .semibold))
                .contentShape(Rectangle())
                .onTapGesture { model.clickTitle(item) }
        }
    }

    private var subtitle: String {
        let ago = ClipPanelText.ago(item.date, now: now)
        return item.title == nil ? ago : "\(item.kind.title) · \(ago)"
    }

    /// Значок заходит за правый верхний угол: края срезает скругление карточки.
    @ViewBuilder private var sourceIcon: some View {
        if let icon = ClipSourceIcon.largeImage(item.sourceBundleID) {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: 74, height: 74)
                .offset(x: 11, y: -4)
                .frame(width: 58, height: Self.headerHeight, alignment: .leading)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
                .padding(.trailing, 14)
        }
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        if concealed {
            Text(ClipConcealment.mask)
                .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            revealedContent
        }
    }

    @ViewBuilder private var revealedContent: some View {
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
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 68, height: 68)
                } else {
                    Image(systemName: "link").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let image = model.image(item) {
                // Целиком, вписанной по центру, на фоне карточки: у узкой и длинной по бокам поля, края не срезаются.
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: Self.width, height: Self.pictureHeight)
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            // Миниатюра есть только у файла-картинки, сделанная при копировании или по кнопке. Файл-картинка в
            // «спрашиваемой» папке без доступа — значок типа и кнопка «Показать превью». Остальное — список имён, как раньше.
            if item.thumbnailFile != nil {
                filePicture
            } else if let folder = model.askFolder(item) {
                fileAsk(folder)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array((item.filePaths ?? []).prefix(5)), id: \.self) { path in
                        HStack(spacing: 7) {
                            fileIcon(path)
                            fileName(path)
                        }
                    }
                }
                .padding(.horizontal, ClipboardPreview.textInset).padding(.top, 12)
            }
        }
    }

    /// Высота области картинки: между шапкой и низом (`ClipThumbnail.cardArea`).
    static let pictureHeight = height - headerHeight - footerHeight

    /// Путь показанного файла: первого файла-картинки, иначе первого.
    private var shownPath: String {
        let paths = item.filePaths ?? []
        return ClipFileThumbnail.shownIndex(in: paths).map { paths[$0] } ?? paths.first ?? ""
    }

    /// Миниатюра первого файла-картинки целиком над полосой с его именем и «+N» за остальные файлы.
    private var filePicture: some View {
        let shown = shownPath
        return fileArea(shown: shown) { ClipFilePicture(item: item, shown: shown, shownAt: now, model: model) }
    }

    /// Файл-картинка в «спрашиваемой» папке: значок типа и кнопка, полоса с именем та же.
    private func fileAsk(_ folder: ClipAskFolder) -> some View {
        let shown = shownPath
        return fileArea(shown: shown) { ClipFileAsk(item: item, folder: folder, shown: shown, model: model, previews: model.filePreviews) }
    }

    /// Картинка над полосой, а не под ней: полоса не закрывает низ вписанной картинки. `shown` — путь показанного файла,
    /// считается один раз на карточку: тип по расширению берётся из базы типов.
    private func fileArea<Picture: View>(shown: String, @ViewBuilder _ picture: () -> Picture) -> some View {
        let paths = item.filePaths ?? []
        return VStack(spacing: 0) {
            picture()
                .frame(width: Self.width, height: Self.pictureHeight - Self.fileStripHeight)
            HStack(spacing: 7) {
                fileIcon(shown)
                fileName(shown)
                Spacer(minLength: 0)
                if paths.count > 1 {
                    Text(verbatim: "+\(paths.count - 1)").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize()
                }
            }
            .padding(.horizontal, ClipboardPreview.textInset)
            .frame(width: Self.width, height: Self.fileStripHeight)
            .background(.black.opacity(0.55))
        }
    }

    static let fileStripHeight: CGFloat = 28

    private func fileName(_ path: String) -> some View {
        Text((path as NSString).lastPathComponent).font(.system(size: ClipboardPreview.fontSize))
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.92))
    }

    /// Значок типа по расширению, файл не читается. Без расширения тип не узнать — прежний общий значок.
    @ViewBuilder private func fileIcon(_ path: String) -> some View {
        if let icon = ClipFileTypeIcon.image(path) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
        } else {
            Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Низ

    static let footerHeight: CGFloat = 34
    static let captionSize: CGFloat = 12
    static let captionMinScale: CGFloat = 0.8
    /// Место под подпись: ширина текста минус номер и зазор до него.
    static let captionRoom = ClipboardPreview.textWidth - 30
    private static let linkFooterHeight: CGFloat = 52

    @ViewBuilder private var footer: some View {
        if item.kind == .link && !concealed {
            linkFooter
        } else {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Подпись о скрытых строках нельзя обрезать: в конце самое важное. Номер не сжимается, подпись ужимается сама.
                Text(concealed ? "" : caption).font(.system(size: Self.captionSize)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(Self.captionMinScale)
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
            // Номер меняется сразу: в общей анимации смыкания старый и новый просвечивали бы друг через друга.
            Text("⌘\(number)").font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
                .contentTransition(.identity)
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
        if groupCount > 1 { groupMenu } else { singleMenu }
    }

    @ViewBuilder private var groupMenu: some View {
        Button("Вставить \(groupCount)") { model.pasteSelected() }
        Menu("В пространство") {
            ForEach(spaces) { space in
                Button(space.name) { model.pinSelected(to: space.id) }
            }
            if spaces.isEmpty { Text("Пространств нет — создай кнопкой + вверху") }
        }
        Divider()
        Button("Удалить \(groupCount)", role: .destructive) { model.beginDeleteSelected() }
    }

    @ViewBuilder private var singleMenu: some View {
        Button("Вставить") { model.onPaste(item) }
        Button("Переименовать") { model.beginTitleEdit(item) }
        if ClipConcealment.isHidden(item, in: spaces) {
            if concealed {
                Button("Показать") { model.reveal(item.id) }
            } else {
                Button("Скрыть") { model.conceal(item.id) }
            }
        }
        Menu("В пространство") {
            ForEach(spaces) { space in
                Button(space.name) { model.pin(item.id, to: space.id) }
            }
            if spaces.isEmpty { Text("Пространств нет — создай кнопкой + вверху") }
        }
        if item.spaceID != nil {
            Button("Убрать из пространства") { model.pin(item.id, to: nil) }
        }
        Divider()
        Button("Удалить", role: .destructive) { model.delete(item.id) }
    }
}

/// Поле правки на месте: название карточки и имя категории. Клавиатуру забирает на время правки, текст при получении фокуса выделен.
struct ClipInlineField: View {
    let placeholder: String
    let font: Font
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear {
                focused = true
                DispatchQueue.main.async {
                    for window in NSApp.windows { (window.firstResponder as? NSTextView)?.selectAll(nil) }
                }
            }
    }
}
