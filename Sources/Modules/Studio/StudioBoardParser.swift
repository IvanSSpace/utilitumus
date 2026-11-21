import Foundation
import ImageIO

/// Ответ сервера Студии → снимок для провода. Сервер пишут мастера и автор, но его ответ всё равно данные: каждое поле
/// проверяется и обрезается здесь, неизвестное отбрасывается. Утилита не падает на кривом ответе, а возвращает nil.
enum StudioBoardParser {
    static let maxUnits = 64
    static let maxHubTasks = 50
    static let maxQueue = 200
    static let maxCaseChars = 40_000
    static let maxLine = 300
    /// Значок на проводе: PNG не больше этого после сжатия до `iconSide` точек.
    static let maxIconBytes = 32 * 1024
    static let iconSide = 80
    /// Больше значок сервера не бывает (он отдаёт 256): крупнее — не значок.
    static let maxIconPixels = 1024

    struct Parsed: Equatable {
        var units: [StudioUnit]
        var hubTasks: [StudioHubTask]
        var orcaError: String?
    }

    /// Одна строка: без управляющих знаков (в том числе переводов строки), не длиннее `limit`.
    static func line(_ value: Any?, limit: Int = maxLine) -> String? {
        guard let text = value as? String else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if StudioText.breaksLine(scalar) { scalars.append(" ") } else if !StudioText.isHidden(scalar) { scalars.append(scalar) }
        }
        return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// Много строк (дело, задача): перевод строки и табуляция остаются.
    static func block(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !StudioText.isHidden($0) }))
        return String(cleaned.prefix(limit))
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        return d.isFinite && abs(d) < 1e12 ? Int(d) : nil
    }

    private static func isTint(_ text: String) -> Bool {
        text.utf8.count == 7 && text.hasPrefix("#") && text.utf8.dropFirst().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    // MARK: /api/state

    static func state(from data: Data) -> Parsed? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawUnits = root["units"] as? [Any] else { return nil }
        var seen = Set<String>()
        let units: [StudioUnit] = rawUnits.prefix(maxUnits).compactMap { raw in
            guard let unit = unit(raw), seen.insert(unit.id).inserted else { return nil }
            return unit
        }
        let tasks: [StudioHubTask] = ((root["hubTasks"] as? [Any]) ?? []).prefix(maxHubTasks).compactMap { raw in
            guard let item = raw as? [String: Any], let name = line(item["name"], limit: 120), !name.isEmpty else { return nil }
            return StudioHubTask(name: name, status: line(item["status"], limit: 40) ?? "", comment: line(item["comment"], limit: 200) ?? "")
        }
        let error = line(root["orcaError"]).flatMap { $0.isEmpty ? nil : $0 }
        return Parsed(units: units, hubTasks: tasks, orcaError: error)
    }

    private static func unit(_ raw: Any) -> StudioUnit? {
        guard let item = raw as? [String: Any], let id = item["id"] as? String, StudioUnitID.isValid(id),
              let kind = (item["kind"] as? String).flatMap(StudioUnitKind.init(rawValue:)),
              let title = line(item["title"], limit: 80), !title.isEmpty else { return nil }
        let master = item["master"] as? [String: Any]
        let session = master?["session"] as? [String: Any]
        let tint = (item["tint"] as? String).flatMap { isTint($0) ? $0 : nil } ?? "#8e8e93"
        let worktree = item["worktree"] as? [String: Any]
        var rotation: StudioRotation?
        if let rot = item["rotation"] as? [String: Any], let stage = line(rot["stage"], limit: 20) {
            rotation = StudioRotation(stage: stage, message: line(rot["message"]) ?? "")
        }
        let version = line(item["version"], limit: 40).flatMap { $0.isEmpty ? nil : $0 }
        return StudioUnit(
            id: id, kind: kind, title: title, summary: line(item["summary"]) ?? "", tint: tint,
            version: version, status: line(item["status"], limit: 20),
            openTasks: max(0, int(item["openTasks"]) ?? 0), bugs: max(0, int(item["bugs"]) ?? 0),
            hasIcon: (item["icon"] as? Bool) ?? false,
            branch: line(worktree?["branch"], limit: 120).flatMap { $0.isEmpty ? nil : $0 },
            ahead: int(worktree?["ahead"]).map { max(0, $0) },
            master: (master?["state"] as? String).flatMap(StudioMasterState.init(rawValue:)) ?? .none,
            contextPct: int(session?["contextPct"]).map { min(max($0, 0), 999) },
            lastActive: int(session?["lastActive"]).map(Int64.init),
            rotation: rotation)
    }

    // MARK: /api/unit/<id>

    static func detail(from data: Data, id: String) -> StudioDetail? {
        guard StudioUnitID.isValid(id), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let queue: [StudioQueueItem] = ((root["queue"] as? [Any]) ?? []).prefix(maxQueue).compactMap { raw in
            guard let item = raw as? [String: Any], let text = block(item["text"], limit: 600) else { return nil }
            return StudioQueueItem(done: (item["done"] as? Bool) ?? false, text: text)
        }
        return StudioDetail(id: id, caseText: block(root["case"], limit: maxCaseChars) ?? "",
                            casePath: line(root["casePath"], limit: 400) ?? "", queue: queue)
    }

    // MARK: Ответ с ошибкой и действия

    /// Текст из `{"error": …}` или `{"message": …}`: готовая русская строка сервера, без разметки и длинных хвостов.
    static func message(from data: Data, key: String) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = line(root[key], limit: 240), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Значки

    /// PNG сервера (256 точек) → PNG `iconSide` точек. nil — не картинка или не влезла в предел.
    /// Только PNG (по подписи и по разбору ImageIO), не больше `maxIconPixels` по стороне: другие форматы ImageIO и огромные
    /// картинки до декодера не доходят.
    static func icon(from png: Data) -> Data? {
        let options = [kCGImageSourceTypeIdentifierHint: "public.png", kCGImageSourceShouldCache: false] as CFDictionary
        guard png.count <= 512 * 1024, png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let source = CGImageSourceCreateWithData(png as CFData, options),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              (1...maxIconPixels).contains(width), (1...maxIconPixels).contains(height),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: iconSide,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest), out.length <= maxIconBytes else { return nil }
        return out as Data
    }
}
