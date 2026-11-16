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
    /// Рамка миниатюры в точках картинки: карточка на Retina с запасом, с округлением вверх (533×348).
    static let frame = (width: Int((cardArea.width * scale).rounded(.up)), height: Int((cardArea.height * scale).rounded(.up)))
    /// Жёсткий предел байт. Обычный снимок экрана выходит в десятки КБ; не влезла — ниже качество, потом меньше размер.
    static let maxBytes = 150 * 1024
    /// Предел миниатюры скопированного файла. Карточка та же, но запись-файл не несёт полного снимка рядом, и таких
    /// записей в истории больше, чем картинок: хватает худшего качества, снимок экрана всё равно узнаётся.
    static let fileMaxBytes = 40 * 1024
    /// Предел стороны миниатюры. Вписанная в `frame` его не достигает; страховка для ImageIO и для разжатия карточкой
    /// (`ClipScreenPicture`): больше этого — уже не миниатюра.
    static let maxSide = 4096

    /// nil — данные не картинка, картинка битая или больше предела точек.
    static func make(from data: Data, maxBytes: Int = maxBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return make(from: source, maxBytes: maxBytes)
    }

    static func make(from source: CGImageSource, maxBytes: Int = maxBytes) -> Data? {
        guard let image = fitted(source) else { return nil }
        return encoded(image, maxBytes: maxBytes)
    }

    /// Картинка целиком, вписанная в `frame`: ничего не срезано, пропорция исходной. Карточка вписывает её так же
    /// (`scaledToFit` по центру), у узкой и длинной по бокам остаются поля. ImageIO уменьшает сразу до нужного,
    /// полный размер в памяти не собирается. Сверх предела точек, как у TIFF из буфера, не разжимаем вовсе: маленький
    /// файл может развернуться в гигапиксели.
    private static func fitted(_ source: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= ClipboardPolicy.maxTIFFPixels / height else { return nil }
        // Повёрнутая по EXIF картинка ляжет боком: стороны меняются местами (ориентации 5–8).
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let (w, h) = turned ? (Double(height), Double(width)) : (Double(width), Double(height))
        // Вписывание: меньший из коэффициентов, одна сторона достаёт до своей стороны рамки, другая не больше своей.
        // Крупнее исходной не бывает.
        let fit = min(1, Double(frame.width) / w, Double(frame.height) / h)
        let side = min(maxSide, max(1, Int((max(w, h) * fit).rounded())))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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

/// Что вышло с миниатюрой файла записи.
enum ClipFileResult: Equatable {
    case made(Data)
    /// Файл в «спрашиваемой» папке, доступа к которой автор ещё не давал: на карточке кнопка «Показать превью».
    case needsAccess(ClipAskFolder)
    /// macOS не дала доступа к этой папке: кнопка остаётся, под ней подсказка про Настройки.
    case denied(ClipAskFolder)
    /// Нельзя или незачем: закрытая папка, ссылка в другую папку, файла нет, не картинка, больше предела, только в iCloud.
    case unavailable

    var data: Data? {
        if case .made(let data) = self { return data }
        return nil
    }
}

/// Миниатюра скопированного файла-картинки для карточки. Вставка и перенос по-прежнему отдают сам файл.
/// Значок, который Finder кладёт в буфер рядом с адресом, миниатюрой не считается: в нём общий значок типа («PNG»),
/// а не содержимое картинки.
enum ClipFileThumbnail {
    /// Картинка ли файл — по расширению, без чтения файла.
    static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    /// Чью миниатюру показывать: первого файла-картинки в списке. Первым может идти и не картинка, тогда следующего.
    static func shownIndex(in paths: [String]) -> Int? { paths.firstIndex(where: isImage) }

    /// Из самого файла, если его можно открыть: вне защищённых папок или в «спрашиваемой», к которой доступ дан
    /// (`files.granted`) или даётся этим вызовом (`asking`, кнопка на карточке). Иначе карточка покажет значок типа
    /// по расширению, тоже без чтения. У файла не картинки ничего не делается и ничего не читается.
    static func make(path: String, files: ClipFileAccess, asking: ClipAskFolder? = nil) -> ClipFileResult {
        guard isImage(path: path) else { return .unavailable }
        switch files.imageSource(atPath: path, asking: asking) {
        case .source(let source):
            return ClipThumbnail.make(from: source, maxBytes: ClipThumbnail.fileMaxBytes).map(ClipFileResult.made) ?? .unavailable
        case .needsAccess(let folder): return .needsAccess(folder)
        case .denied(let folder): return .denied(folder)
        case .unavailable: return .unavailable
        }
    }
}

/// Папки дома, доступ к которым macOS спрашивает окном: их файлы «Буфер» читает только после явного нажатия
/// «Показать превью» на карточке (один раз на папку). `rawValue` — имя в виде сравнения и в настройках.
enum ClipAskFolder: String, CaseIterable, Sendable {
    case desktop, documents, downloads

    var title: String {
        switch self {
        case .desktop: return "Рабочий стол"
        case .documents: return "Документы"
        case .downloads: return "Загрузки"
        }
    }
}

/// Где лежит путь, по тексту.
enum ClipPlace: Equatable {
    /// Не защищено: читается без окна прав.
    case open
    /// Рабочий стол, Документы или Загрузки своего дома: только после нажатия.
    case ask(ClipAskFolder)
    /// Не читается никогда и кнопки не имеет: Библиотека, облака, тома, сетевые корни, «Фото», чужие дома.
    case closed
}

/// Папки, файлы из которых «Буфер» сам не открывает: macOS спросила бы разрешение на доступ к ним. Решение только
/// по тексту пути, без обращения к диску.
struct ClipProtectedPaths {
    /// Папки любого дома под защитой системы. Библиотека целиком: в ней iCloud Drive (Mobile Documents), облака
    /// (CloudStorage) и данные других программ. В нижнем регистре: сравнение без учёта регистра, как у APFS по умолчанию.
    static let homeFolders: Set<String> = ["desktop", "documents", "downloads", "library"]
    /// Корни, закрытые целиком: тома (съёмные, сетевые, образы, загрузочный под своим именем) и сетевые точки монтирования.
    static let closedRoots: Set<String> = ["volumes", "network", "net", "home"]

    /// Свои дома, разобранные на компоненты и приведённые к виду сравнения: только в них Рабочий стол, Документы
    /// и Загрузки «спрашиваемые». Те же папки любого другого /Users/<имя> закрыты.
    let homes: [[String]]
    /// Дома, закрытые целиком: в сборке стенда и проверок это настоящий дом.
    let closedHomes: [[String]]

    /// Шов: дома приходят текстом. Проверки передают свои; настоящие берёт только `system`.
    init(homes: [String], closedHomes: [String] = []) {
        func canonical(_ list: [String]) -> [[String]] { list.compactMap { Self.parts($0).map(Self.canonical) }.filter { !$0.isEmpty } }
        self.homes = canonical(homes)
        self.closedHomes = canonical(closedHomes)
    }

    static let system: ClipProtectedPaths = {
        let names = homeNames()
        #if KIT_TEST_DEFAULTS
        // Стенд и проверки: настоящий дом закрыт целиком, даже кнопкой, — окна прав на Mac автора отсюда не будет.
        // «Спрашиваемые» папки только в подставном доме стенда (HOME), если он не настоящий.
        return ClipProtectedPaths(homes: names.process, closedHomes: names.account.map { [$0] } ?? [])
        #else
        return ClipProtectedPaths(homes: names.process + (names.account.map { [$0] } ?? []))
        #endif
    }()

    /// Дом из учётной записи (настоящий) и те, что видит процесс: стенд подменяет HOME, а защищён настоящий. Это только
    /// текст для сравнения путей, к диску по нему не обращаемся (разбор в Tests/stand-reviewed-paths.txt).
    static func homeNames() -> (account: String?, process: [String]) {
        let account = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
        let environment = ProcessInfo.processInfo.environment
        return (account, [NSHomeDirectory(), environment["HOME"], environment["CFFIXED_USER_HOME"]].compactMap { $0 })
    }

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

    /// Не абсолютный путь закрыт.
    func place(path: String) -> ClipPlace {
        guard let parts = Self.parts(path) else { return .closed }
        return place(parts)
    }

    /// `parts` — компоненты уже без «.» и «..».
    func place(_ parts: [String]) -> ClipPlace {
        let c = Self.canonical(parts)
        guard let first = c.first else { return .open }
        // Служебные корни с точкой (/.vol, /.file, /.nofollow, /.resolve) открывают файл в обход обычного пути.
        if first.hasPrefix(".") || Self.closedRoots.contains(first) { return .closed }
        // Медиатека «Фото» где угодно: её файлы система тоже бережёт.
        if c.contains(where: { $0.hasSuffix(".photoslibrary") }) { return .closed }
        if closedHomes.contains(where: { c.count > $0.count && Array(c.prefix($0.count)) == $0 }) { return .closed }
        for home in homes where c.count > home.count && Array(c.prefix(home.count)) == home {
            if let folder = ClipAskFolder(rawValue: c[home.count]) { return .ask(folder) }
            if Self.homeFolders.contains(c[home.count]) { return .closed }
        }
        if first == "users", c.count >= 3, Self.homeFolders.contains(c[2]) { return .closed }
        return .open
    }

    /// Защищённая папка (любого класса) или что-то внутри неё.
    func contains(path: String) -> Bool { place(path: path) != .open }
}

/// Что вышло у открытия пути записи.
enum ClipFileOpen {
    case source(CGImageSource)
    case needsAccess(ClipAskFolder)
    case denied(ClipAskFolder)
    case unavailable
}

/// Что сказала система про уже проверенный путь.
enum ClipFileOpened {
    case source(CGImageSource)
    /// Отказ в доступе (EPERM, EACCES): у «спрашиваемой» папки это отказ macOS.
    case denied
    case unavailable
}

/// Единственный путь к содержимому файла из записи (страж в Tests/run-clipboard-check.sh): путь проверяется по тексту,
/// потом по настоящему пути без ссылок, и только потом файл открывается. Части подставные в проверке: так видно, что
/// защищённого пути не коснулось ничто.
struct ClipFileAccess {
    var protected: ClipProtectedPaths
    /// «Спрашиваемые» папки, доступ к которым автор уже дал кнопкой (флаг в настройках утилиты). Остальные не читаются.
    var granted: Set<ClipAskFolder> = []
    /// Цель символической ссылки, nil — не ссылка. Зовётся только для путей, которые этот вызов читать вправе.
    var readLink: (String) -> String?
    /// Открыть путь, который уже прошёл проверку.
    var open: (URL) -> ClipFileOpened

    static let maxLinks = 32
    /// Больше — как «нельзя прочитать»: миниатюра не стоит того, чтобы читать огромный файл.
    static let maxFileBytes = 50 * 1024 * 1024

    static func system(granted: Set<ClipAskFolder>) -> ClipFileAccess {
        ClipFileAccess(protected: .system, granted: granted, readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                       open: openChecked)
    }

    /// Читается ли путь сейчас без нажатия: по тексту, без диска.
    func readsWithoutAsking(_ path: String) -> Bool { allows(protected.place(path: path), granted) }

    private func allows(_ place: ClipPlace, _ allowed: Set<ClipAskFolder>) -> Bool {
        switch place {
        case .open: return true
        case .ask(let folder): return allowed.contains(folder)
        case .closed: return false
        }
    }

    /// Источник ImageIO, если файл можно открыть. `asking` — папка, доступ к которой даёт это нажатие кнопки: только
    /// на этот вызов и только к ней. Ссылка в другую «спрашиваемую» папку отклоняется: это был бы другой запрос.
    func imageSource(atPath path: String, asking: ClipAskFolder? = nil) -> ClipFileOpen {
        let allowed = asking.map { granted.union([$0]) } ?? granted
        // (а) По тексту: в закрытое и в неразрешённое не заходим вовсе, даже чтением ссылок.
        let place = protected.place(path: path)
        if case .ask(let folder) = place, !allowed.contains(folder) { return .needsAccess(folder) }
        guard allows(place, allowed),
              // (б) Настоящий путь и проверка ещё раз: ссылка могла вести в закрытую или в другую «спрашиваемую» папку.
              let real = resolved(path, allowed: allowed), allows(protected.place(path: real), allowed) else { return .unavailable }
        // (в) Только теперь сам файл.
        switch open(URL(fileURLWithPath: real)) {
        case .source(let source): return .source(source)
        case .denied:
            if case .ask(let folder) = protected.place(path: real) { return .denied(folder) }
            return .unavailable
        case .unavailable: return .unavailable
        }
    }

    /// Настоящий путь без символических ссылок. Идёт по компонентам, как ядро: «..» после ссылки — от её цели.
    /// Каждый шаг сначала проверяется: в закрытую и неразрешённую папку разбор не заходит даже чтением ссылки
    /// (`resolvingSymlinksInPath` дошёл бы до конца). nil — дошёл до такой папки, ссылок слишком много или путь не абсолютный.
    func resolved(_ path: String, allowed: Set<ClipAskFolder>) -> String? {
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
            guard allows(protected.place(done), allowed) else { return nil }
            guard let target = readLink("/" + done.joined(separator: "/")) else { continue }
            links += 1
            guard links <= Self.maxLinks else { return nil }
            done.removeLast()
            if target.hasPrefix("/") { done = [] }
            pending = target.split(separator: "/").map(String.init) + pending
        }
        return "/" + done.joined(separator: "/")
    }

    /// Метаданные читаются только здесь, у пути, который уже прошёл проверку: обычный файл на внутреннем несъёмном диске,
    /// не больше предела и не лежащий только в iCloud (чтение запустило бы скачивание). Отказ системы (окно прав
    /// отклонено или доступ снят в Настройках) отличается от остального: у «спрашиваемой» папки это «нет доступа».
    private static func openChecked(_ url: URL) -> ClipFileOpened {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                         .volumeIsRemovableKey, .volumeIsEjectableKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            return isDenial(error) ? .denied : .unavailable
        }
        guard values.isRegularFile == true, let size = values.fileSize, size <= maxFileBytes,
              values.volumeIsLocal == true, values.volumeIsInternal == true,
              values.volumeIsRemovable != true, values.volumeIsEjectable != true,
              !onlyInCloud(ubiquitous: values.isUbiquitousItem, status: values.ubiquitousItemDownloadingStatus) else { return .unavailable }
        // Метаданные система могла отдать, а чтение нет: открытие на пробу различает отказ и прочее до ImageIO,
        // которая отказ не отличила бы от битой картинки.
        do {
            try FileHandle(forReadingFrom: url).close()
        } catch {
            return isDenial(error) ? .denied : .unavailable
        }
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary).map(ClipFileOpened.source) ?? .unavailable
    }

    /// Файл в iCloud, но не загружен (или загружен не последний): чтение запустило бы скачивание.
    static func onlyInCloud(ubiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        ubiquitous == true && status != .current
    }

    /// Отказ в доступе, а не «нет файла» или «не читается»: так macOS отвечает на запрещённую папку.
    static func isDenial(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
            if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
