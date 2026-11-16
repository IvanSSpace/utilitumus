import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Миниатюра картинки для карточки панели. Карточка показывает её вместо полного снимка: иначе каждое открытие
/// панели заново разжимало бы мегапиксели на главном потоке. Делается из данных или из готового источника ImageIO,
/// поэтому подойдёт и картинкам-файлам. Без AppKit: проверяется отдельно.
enum ClipThumbnail {
    /// Где карточка рисует картинку, в точках: вся ширина карточки и высота между шапкой и низом
    /// (`ClipCard.width` × `ClipCard.height - headerHeight - footerHeight`, сверка в Tests/ClipboardPanelCheck.swift).
    static let cardArea = CGSize(width: 242, height: 158)
    /// Retina ×2 и запас 10%: на экране ×2 точка миниатюры не крупнее точки экрана, а небольшая перемена карточки
    /// не требует переделывать сохранённые миниатюры.
    static let scale: CGFloat = 2.2
    /// Жёсткий предел байт. Обычный снимок экрана выходит в десятки КБ; не влезла — ниже качество, потом меньше размер.
    static let maxBytes = 150 * 1024
    /// Предел миниатюры скопированного файла. Карточка та же, но запись-файл не несёт полного снимка рядом, и таких
    /// записей в истории больше, чем картинок: хватает худшего качества, снимок экрана всё равно узнаётся.
    static let fileMaxBytes = 40 * 1024
    /// Предел длинной стороны при уменьшении. Длинный снимок страницы иначе разжимался бы в тысячи точек ради середины,
    /// которую карточка показывает.
    static let maxSide = 4096

    /// nil — данные не картинка, картинка битая или больше предела точек.
    static func make(from data: Data, maxBytes: Int = maxBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return make(from: source, maxBytes: maxBytes)
    }

    /// `index` — какая из картинок источника: у значка ICNS и многостраничного TIFF их несколько, по одной на размер.
    static func make(from source: CGImageSource, index: Int = 0, maxBytes: Int = maxBytes) -> Data? {
        guard let image = cropped(source, index: index) else { return nil }
        return encoded(image, maxBytes: maxBytes)
    }

    /// ImageIO уменьшает сразу до нужного, полный размер в памяти не собирается. Потом середина в пропорции карточки:
    /// ровно то, что карточка показывает при заполнении (`scaledToFill` по центру и обрезка краёв).
    /// Сверх предела точек, как у TIFF из буфера, не разжимаем вовсе: маленький файл может развернуться в гигапиксели.
    private static func cropped(_ source: CGImageSource, index: Int) -> CGImage? {
        guard index >= 0, CGImageSourceGetCount(source) > index,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= ClipboardPolicy.maxTIFFPixels / height else { return nil }
        // Повёрнутая по EXIF картинка ляжет боком: стороны меняются местами (ориентации 5–8).
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let (w, h) = turned ? (Double(height), Double(width)) : (Double(width), Double(height))
        let target = (width: Double(cardArea.width * scale), height: Double(cardArea.height * scale))
        // Заполнение: меньшая из сторон закрывает свою сторону карточки. Крупнее исходной не бывает.
        let fill = min(1, max(target.width / w, target.height / h))
        let side = min(maxSide, Int((max(w, h) * fill).rounded(.up)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let aspect = cardArea.width / cardArea.height
        let tw = CGFloat(thumbnail.width), th = CGFloat(thumbnail.height)
        let crop = tw / th > aspect
            ? CGRect(x: ((tw - th * aspect) / 2).rounded(.down), y: 0, width: (th * aspect).rounded(), height: th)
            : CGRect(x: 0, y: ((th - tw / aspect) / 2).rounded(.down), width: tw, height: (tw / aspect).rounded())
        return thumbnail.cropping(to: crop) ?? thumbnail
    }

    /// JPEG у непрозрачной картинки: снимок экрана выходит в десятки КБ и разжимается быстрее PNG. С настоящей
    /// прозрачностью PNG, иначе она стала бы чёрной. Признаку альфы из заголовка не верим: канал альфы есть почти у
    /// любого снимка из буфера, а прозрачных точек нет, поэтому смотрим сами точки миниатюры.
    private static func encoded(_ image: CGImage, maxBytes: Int) -> Data? {
        var size = (width: image.width, height: image.height)
        while true {
            guard let frame = rendered(image, width: size.width, height: size.height) else { return nil }
            var last: Data?
            for quality in frame.opaque ? [0.8, 0.6, 0.45] : [1] {
                guard let data = encode(frame.image, as: frame.opaque ? .jpeg : .png, quality: quality) else { return nil }
                if data.count <= maxBytes { return data }
                last = data
            }
            // Не влезла и при худшем качестве: на четверть меньше по каждой стороне. Совсем маленькая влезает всегда,
            // нижняя граница только страхует цикл.
            guard size.width > 16, size.height > 16 else { return last }
            size = (size.width * 3 / 4, size.height * 3 / 4)
        }
    }

    /// Точки миниатюры в 8 битах на канал и есть ли среди них прозрачные. Пространство цвета прежнее, если это RGB:
    /// снимок в Display P3 не тускнеет.
    private static func rendered(_ image: CGImage, width: Int, height: Int) -> (image: CGImage, opaque: Bool)? {
        // В 8 битах рисуется не всякое пространство (расширенное у HDR-снимка): тогда sRGB.
        let spaces = [image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        let contexts = spaces.lazy.compactMap {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: $0,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = contexts.first else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let made = context.makeImage(), let pixels = context.data else { return nil }
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return (made, true) }
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var opaque = true
        for index in stride(from: 3, to: width * height * 4, by: 4) where bytes[index] != 255 {
            opaque = false
            break
        }
        return (made, opaque)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

// MARK: - Скопированный файл-картинка

/// Миниатюра скопированного файла-картинки для карточки. Вставка и перенос по-прежнему отдают сам файл.
enum ClipFileThumbnail {
    /// Картинок в одном значке не больше этого: ICNS несёт по одной на размер, их около десяти.
    static let maxIconImages = 32

    /// Картинка ли файл — по расширению, без чтения файла.
    static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    /// Чью миниатюру показывать: первого файла-картинки в списке. Первым может идти и не картинка, тогда следующего.
    static func shownIndex(in paths: [String]) -> Int? { paths.firstIndex(where: isImage) }

    /// Источники по порядку. Картинка, которую программа положила в буфер рядом с адресом (Finder — значок файла):
    /// тогда файл не открывается вовсе. Иначе сам файл, если он не в защищённой папке. nil — карточка покажет значок типа
    /// по расширению, тоже без чтения. У файла не картинки ничего не делается: значок рядом с ним — общий значок типа.
    static func make(path: String, icons: [Data], files: ClipFileAccess) -> Data? {
        guard isImage(path: path) else { return nil }
        if let icon = bestIcon(icons),
           let made = ClipThumbnail.make(from: icon.source, index: icon.index, maxBytes: ClipThumbnail.fileMaxBytes) { return made }
        guard let source = files.imageSource(atPath: path) else { return nil }
        return ClipThumbnail.make(from: source, maxBytes: ClipThumbnail.fileMaxBytes)
    }

    /// Из всех картинок значков наименьшая, что закрывает карточку на Retina; нет такой — наибольшая. Гигант не нужен:
    /// его разжатие только тратит время. Предел байт и точек тот же, что у картинки из буфера, размер из заголовка.
    static func bestIcon(_ icons: [Data]) -> (source: CGImageSource, index: Int)? {
        let need = (width: Int((ClipThumbnail.cardArea.width * ClipThumbnail.scale).rounded(.up)),
                    height: Int((ClipThumbnail.cardArea.height * ClipThumbnail.scale).rounded(.up)))
        var best: (source: CGImageSource, index: Int, pixels: Int, covers: Bool)?
        for data in icons where data.count <= ClipboardPolicy.maxTIFFBytes {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            for index in 0..<min(CGImageSourceGetCount(source), maxIconImages) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      ClipboardPolicy.tiffFits(bytes: data.count, width: width, height: height) else { continue }
                let candidate = (pixels: width * height, covers: width >= need.width && height >= need.height)
                if let current = best, !preferred(candidate, over: (current.pixels, current.covers)) { continue }
                best = (source, index, candidate.pixels, candidate.covers)
            }
        }
        return best.map { ($0.source, $0.index) }
    }

    /// Закрывающая карточку лучше незакрывающей; из закрывающих меньшая, из остальных большая.
    private static func preferred(_ a: (pixels: Int, covers: Bool), over b: (pixels: Int, covers: Bool)) -> Bool {
        if a.covers != b.covers { return a.covers }
        return a.covers ? a.pixels < b.pixels : a.pixels > b.pixels
    }
}

/// Папки, файлы из которых «Буфер» не открывает: macOS спросила бы разрешение на доступ к ним, а новых окон прав у утилиты
/// быть не должно. Решение только по тексту пути, без обращения к диску.
struct ClipProtectedPaths {
    /// Папки дома под защитой системы. Библиотека целиком: в ней iCloud Drive (Mobile Documents), облака (CloudStorage)
    /// и данные других программ. В нижнем регистре: сравнение без учёта регистра, как у APFS по умолчанию.
    static let homeFolders: Set<String> = ["desktop", "documents", "downloads", "library"]
    /// Корни, закрытые целиком: тома (съёмные, сетевые, образы, загрузочный под своим именем) и сетевые точки монтирования.
    static let closedRoots: Set<String> = ["volumes", "network", "net", "home"]

    /// Дома, разобранные на компоненты и приведённые к виду сравнения. Кроме них закрыты те же папки любого /Users/<имя>.
    let homes: [[String]]

    init(homes: [String]) {
        self.homes = homes.compactMap { Self.parts($0).map(Self.canonical) }
    }

    /// Дом из учётной записи и тот, что видит Foundation: стенд подменяет HOME, а защищён настоящий.
    static let system: ClipProtectedPaths = {
        var homes = [NSHomeDirectory()]
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { homes.append(String(cString: dir)) }
        let environment = ProcessInfo.processInfo.environment
        homes += [environment["HOME"], environment["CFFIXED_USER_HOME"]].compactMap { $0 }
        return ClipProtectedPaths(homes: homes)
    }()

    /// Компоненты абсолютного пути по тексту: без пустых и «.», «..» снимает предыдущий. nil — путь не абсолютный.
    /// «..» после символической ссылки ядро считает от её цели: это разбирает `ClipFileAccess.resolved`, здесь только текст.
    static func parts(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var out: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !out.isEmpty { out.removeLast() }
                continue
            }
            out.append(String(part))
        }
        return out
    }

    /// Вид для сравнения: нижний регистр, составные буквы, без /System/Volumes/Data и /private в начале — через них
    /// виден тот же каталог.
    static func canonical(_ parts: [String]) -> [String] {
        var c = parts.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        while true {
            if c.count >= 3, c[0] == "system", c[1] == "volumes", c[2] == "data" {
                c.removeFirst(3)
            } else if c.first == "private" {
                c.removeFirst()
            } else {
                return c
            }
        }
    }

    /// Защищённая папка или что-то внутри неё. Не абсолютный путь считается защищённым.
    func contains(path: String) -> Bool {
        guard let parts = Self.parts(path) else { return true }
        return contains(parts)
    }

    /// `parts` — компоненты уже без «.» и «..».
    func contains(_ parts: [String]) -> Bool {
        let c = Self.canonical(parts)
        guard let first = c.first else { return false }
        // Служебные корни с точкой (/.vol, /.file, /.nofollow, /.resolve) открывают файл в обход обычного пути.
        if first.hasPrefix(".") || Self.closedRoots.contains(first) { return true }
        // Медиатека «Фото» где угодно: её файлы система тоже бережёт.
        if c.contains(where: { $0.hasSuffix(".photoslibrary") }) { return true }
        if first == "users", c.count >= 3, Self.homeFolders.contains(c[2]) { return true }
        return homes.contains { home in
            c.count > home.count && Array(c.prefix(home.count)) == home && Self.homeFolders.contains(c[home.count])
        }
    }
}

/// Единственный путь к содержимому файла из записи (страж в Tests/run-clipboard-check.sh): путь проверяется по тексту,
/// потом по настоящему пути без ссылок, и только потом файл открывается. Части подставные в проверке: так видно, что
/// защищённого пути не коснулось ничто.
struct ClipFileAccess {
    var protected: ClipProtectedPaths
    /// Цель символической ссылки, nil — не ссылка. Зовётся только для путей вне защищённых папок.
    var readLink: (String) -> String?
    /// Открыть путь, который уже прошёл проверку.
    var open: (URL) -> CGImageSource?

    static let maxLinks = 32
    /// Больше — как «нельзя прочитать»: миниатюра не стоит того, чтобы читать огромный файл.
    static let maxFileBytes = 50 * 1024 * 1024

    static var system: ClipFileAccess {
        ClipFileAccess(protected: .system, readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                       open: openChecked)
    }

    /// Источник ImageIO, если файл можно открыть без окна прав. nil — защищённая папка, ссылка в неё, не обычный файл,
    /// не внутренний диск или файл больше предела.
    func imageSource(atPath path: String) -> CGImageSource? {
        // (а) По тексту: в явно защищённое не заходим вовсе, даже чтением ссылок.
        guard !protected.contains(path: path),
              // (б) Настоящий путь и проверка ещё раз: ссылка из временной папки могла вести в защищённую.
              let real = resolved(path), !protected.contains(path: real) else { return nil }
        // (в) Только теперь сам файл.
        return open(URL(fileURLWithPath: real))
    }

    /// Настоящий путь без символических ссылок. Идёт по компонентам, как ядро: «..» после ссылки — от её цели.
    /// Каждый шаг сначала проверяется: в защищённую папку разбор не заходит даже чтением ссылки (`resolvingSymlinksInPath`
    /// дошёл бы до конца). nil — дошёл до защищённой папки, ссылок слишком много или путь не абсолютный.
    func resolved(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var pending = path.split(separator: "/").map(String.init)
        var done: [String] = []
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." {
                if !done.isEmpty { done.removeLast() }
                continue
            }
            done.append(part)
            guard !protected.contains(done) else { return nil }
            guard let target = readLink("/" + done.joined(separator: "/")) else { continue }
            links += 1
            guard links <= Self.maxLinks else { return nil }
            done.removeLast()
            if target.hasPrefix("/") { done = [] }
            pending = target.split(separator: "/").map(String.init) + pending
        }
        return "/" + done.joined(separator: "/")
    }

    /// Метаданные читаются только здесь, у пути, который уже прошёл проверку: обычный файл на внутреннем несъёмном диске
    /// и не больше предела. Остальное — как «нельзя прочитать».
    private static func openChecked(_ url: URL) -> CGImageSource? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                         .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, size <= maxFileBytes,
              values.volumeIsLocal == true, values.volumeIsInternal == true,
              values.volumeIsRemovable != true, values.volumeIsEjectable != true else { return nil }
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
