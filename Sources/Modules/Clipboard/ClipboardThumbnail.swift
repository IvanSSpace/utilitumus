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
    /// Предел длинной стороны при уменьшении. Длинный снимок страницы иначе разжимался бы в тысячи точек ради середины,
    /// которую карточка показывает.
    static let maxSide = 4096

    /// nil — данные не картинка, картинка битая или больше предела точек.
    static func make(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return make(from: source)
    }

    static func make(from source: CGImageSource) -> Data? {
        guard let image = cropped(source) else { return nil }
        return encoded(image)
    }

    /// ImageIO уменьшает сразу до нужного, полный размер в памяти не собирается. Потом середина в пропорции карточки:
    /// ровно то, что карточка показывает при заполнении (`scaledToFill` по центру и обрезка краёв).
    /// Сверх предела точек, как у TIFF из буфера, не разжимаем вовсе: маленький файл может развернуться в гигапиксели.
    private static func cropped(_ source: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
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
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
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
    private static func encoded(_ image: CGImage) -> Data? {
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
