import AppKit
import CryptoKit
import SwiftUI

// Ленты кадров анимаций панели: настоящий ход анимации вне экрана, сетка кадров в PNG и таблица изменений.
// Запуск: CLIPBOARD_FILM_DIR=<папка> Tests/run-clipboard-panel-check.sh. Без этой переменной не запускается.

@MainActor final class Film {
    let host: NSView
    let out: String
    var log = ""

    init(host: NSView, out: String) {
        self.host = host
        self.out = out
    }

    private func capture() -> NSBitmapImageRep {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Отличие двух кадров: сколько точек из сетки 2×2 pt и их рамка. Сырые байты, без перевода цветов.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (count: Int, box: CGRect?) {
        guard let p = a.bitmapData, let q = b.bitmapData, a.bytesPerRow == b.bytesPerRow, a.pixelsHigh == b.pixelsHigh else { return (-1, nil) }
        let scale = a.pixelsWide / max(Int(host.bounds.width), 1)
        let step = max(scale * 2, 1), bytes = a.bitsPerPixel / 8
        var count = 0, minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: step) {
            for x in stride(from: 0, to: a.pixelsWide, by: step) {
                let i = y * a.bytesPerRow + x * bytes
                let d = abs(Int(p[i]) - Int(q[i])) + abs(Int(p[i + 1]) - Int(q[i + 1])) + abs(Int(p[i + 2]) - Int(q[i + 2]))
                if d > 12 {
                    count += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard count > 0 else { return (0, nil) }
        return (count, CGRect(x: minX / scale, y: minY / scale, width: (maxX - minX) / scale, height: (maxY - minY) / scale))
    }

    /// Снимает кадры с момента действия. `frames` кадров как можно чаще, время каждого в подписи.
    func shoot(_ name: String, frames: Int = 24, settle: Double = 0.5, _ action: () -> Void) async {
        await pause(settle)
        host.layoutSubtreeIfNeeded()
        var shots: [(t: Double, bitmap: NSBitmapImageRep)] = [(0, capture())]
        let start = ProcessInfo.processInfo.systemUptime
        action()
        for _ in 1..<frames {
            await pause(0.012)
            shots.append((ProcessInfo.processInfo.systemUptime - start, capture()))
        }
        await pause(0.6)
        let last = capture()
        write(name, shots)
        var table = "== \(name)\n"
        var lastChange = 0.0
        for (i, shot) in shots.enumerated() where i > 0 {
            let step = difference(shots[i - 1].bitmap, shot.bitmap)
            let toEnd = difference(shot.bitmap, last)
            if step.count > 0 { lastChange = shot.t }
            let box = step.box.map { "x\(Int($0.minX))…\(Int($0.maxX)) y\(Int($0.minY))…\(Int($0.maxY))" } ?? "-"
            table += String(format: "%5.0f мс  шаг %5d  до конца %5d  %@\n", shot.t * 1000, step.count, toEnd.count, box)
        }
        table += String(format: "последнее изменение %.0f мс, конец: %d точек от последнего снятого\n", lastChange * 1000, difference(shots.last!.bitmap, last).count)
        log += table
        print(table, terminator: "")
    }

    private func write(_ name: String, _ all: [(t: Double, bitmap: NSBitmapImageRep)]) {
        // Только кадры, где что-то изменилось: длинный хвост покоя лента не показывает. Последний всегда есть.
        var shots: [(t: Double, bitmap: NSBitmapImageRep)] = []
        for (i, shot) in all.enumerated() where i == 0 || difference(all[i - 1].bitmap, shot.bitmap).count > 0 { shots.append(shot) }
        let columns = 3, width = 840, height = Int(CGFloat(width) * host.bounds.height / host.bounds.width)
        let rows = (shots.count + columns - 1) / columns
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns * width, pixelsHigh: rows * height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        for (i, shot) in shots.enumerated() {
            let x = (i % columns) * width, y = (rows - 1 - i / columns) * height
            shot.bitmap.draw(in: NSRect(x: x, y: y, width: width - 2, height: height - 2), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            String(format: "%.0f мс", shot.t * 1000).draw(at: NSPoint(x: x + 4, y: y + 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.yellow])
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}

@MainActor func runFilms(out: String) async {
    var log = ""
    Kit.defaults.set("vivid", forKey: DSTheme.storageKey)
    let now = Date()

    /// Панель на настоящем контроллере и временном хранилище: то, что делает настоящая панель, кроме окна.
    func stand() -> (OrderStand, ClipSpace, ClipSpace, Film) {
        let stand = OrderStand()
        let store = stand.store
        let work = store.addSpace(name: "работа", colorID: "red")
        let home = store.addSpace(name: "дом и длинное имя", colorID: "green")
        _ = store.addSpace(name: "гайды", colorID: "blue")
        let texts = ["Нет общего состояния, агенты не мешают друг другу.", "m.docker.socket:", "Жёлтый значок заметок", "https://example.com/invite/abc",
                     "Девятая карточка", "Строка один\nСтрока два\nСтрока три", "Седьмая запись", "Восьмая запись", "Ещё одна", "И ещё одна запись"]
        for (i, text) in texts.reversed().enumerated() {
            store.ingest(ClipSnapshot(types: [], text: text, sourceBundleID: ["com.apple.Notes", "com.apple.Safari", "com.apple.Terminal"][i % 3], sourceName: "Заметки"), now: now.addingTimeInterval(Double(i - 20) * 60))
        }
        for i in [1, 2, 3, 4, 5] { store.pin(store.items[i].id, to: work.id) }
        ClipboardController.shared.attach(store)
        stand.sync()
        stand.model.pointer = { nil }
        stand.model.isMouseDown = { false }
        let host = Stand.host(stand.model, width: 1440)
        return (stand, work, home, Film(host: host, out: out))
    }

    do {
        let (s, work, _, film) = stand()
        await pause(0.4)
        await film.shoot("01-tab-to-category") { s.model.selectTab(work.id) }
        await film.shoot("02-tab-to-history") { s.model.selectTab(nil) }
        for _ in 0..<7 { s.model.move(1) }
        await film.shoot("03-tab-from-scrolled") { s.model.selectTab(work.id) }
        s.model.selectTab(nil)
        await film.shoot("04-select-click") { s.model.click(s.model.visible[2], at: 2, time: 10) }
        await film.shoot("05-arrow-scroll") { for _ in 0..<4 { s.model.move(1) } }
        await film.shoot("06-arrow-back") { for _ in 0..<6 { s.model.move(-1) } }
        await film.shoot("07-search-open") { _ = s.model.handleKey(ClipPanelKey(code: 0, text: "е")); s.model.query = "е" }
        await film.shoot("08-search-type") { s.model.query = "еще" }
        await film.shoot("09-search-none") { s.model.query = "нет такого" }
        await film.shoot("10-search-back") { s.model.query = "о" }
        await film.shoot("11-search-close") { s.model.closeSearch() }
        await film.shoot("12-plus-create") { s.model.beginCreate() }
        await film.shoot("13-create-cancel") { _ = s.model.handleKey(ClipPanelKey(code: esc, text: "\u{1b}")) }
        s.model.beginCreate()
        await pause(0.3)
        s.model.spaceNameEdit?.text = "Новая категория"
        await film.shoot("14-create-commit") { s.model.commitInlineEdit() }
        s.model.selectTab(nil)
        await film.shoot("15-editor-open") { s.model.beginEdit(s.model.spaces[0]) }
        await film.shoot("16-editor-close") { s.model.closeEditor() }
        await film.shoot("17-title-edit-begin") { s.model.beginTitleEdit(s.model.visible[0]) }
        s.model.titleEdit?.text = "Название карточки"
        await film.shoot("18-title-commit") { s.model.commitInlineEdit() }
        s.close()
    }
    do {
        let (s, work, home, film) = stand()
        await pause(0.4)
        // Наведение и посадка на настоящей цели.
        film.host.layoutSubtreeIfNeeded()
        let tabs = dropTargets(in: film.host)
        let free = s.model.visible.first { $0.spaceID == nil }!
        let drag = s.drag(ClipDrag.recordType, free.id)
        await film.shoot("20-category-hover") { _ = tabs[1].draggingEntered(drag) }
        await film.shoot("21-category-land-dot") { _ = tabs[1].performDragOperation(drag); tabs[1].concludeDragOperation(drag) }
        await film.shoot("21b-pin-from-menu") { s.model.pin(s.model.visible.first { $0.spaceID == nil }!.id, to: work.id) }
        // Снятие: запись уходит из вкладки категории, соседи смыкаются.
        s.model.selectTab(work.id)
        await pause(0.4)
        let leaving = s.model.visible[1]
        let carry = s.drag(ClipDrag.recordType, leaving.id)
        await film.shoot("22-pin-leaves-tab") { _ = tabs[1].performDragOperation(carry); tabs[1].concludeDragOperation(carry) }
        // Перестановка карточек.
        var cursor: CGPoint?
        var down = true
        s.model.pointer = { cursor }
        s.model.isMouseDown = { down }
        func over(_ slot: Int) -> CGPoint { CGPoint(x: cardOrigin(slot).x + ClipCard.width / 2, y: cardOrigin(slot).y + ClipCard.height / 2) }
        cursor = over(0)
        _ = s.model.dragProvider(for: s.model.visible[0])
        await film.shoot("23-reorder-part") { cursor = over(2) }
        await film.shoot("24-reorder-drop") { down = false }
        // Перестановка категорий.
        down = true
        s.model.selectTab(nil)
        await pause(0.3)
        film.host.layoutSubtreeIfNeeded()
        let rects = dropTargets(in: film.host).map { $0.convert($0.bounds, to: nil) }
        let top = ClipPanelMetrics.panelHeight - rects[0].midY
        cursor = CGPoint(x: rects[0].midX, y: top)
        _ = s.model.spaceDragProvider(for: s.model.spaces[0].id)
        await film.shoot("25-space-reorder") { cursor = CGPoint(x: rects[2].maxX - 3, y: top) }
        await film.shoot("26-space-drop") { down = false }
        down = false
        // Показ и скрытие содержимого.
        s.store.setSpaceHidden(home.id, true)
        ClipboardController.shared.attach(s.store)
        s.sync()
        await pause(0.2)
        let hidden = s.model.visible.first { $0.spaceID == home.id }!
        await film.shoot("27-reveal") { s.model.reveal(hidden.id) }
        await film.shoot("28-conceal") { s.model.conceal(hidden.id) }
        // Удаление записи и категории, пустое состояние.
        s.model.selectTab(nil)
        await film.shoot("30-delete-record") { s.model.delete(s.model.visible[1].id) }
        s.model.selectTab(work.id)
        await pause(0.3)
        for item in s.model.visible.dropLast() { s.model.delete(item.id) }
        await film.shoot("31-delete-last-empty") { s.model.delete(s.model.visible[0].id) }
        await film.shoot("32-empty-to-history") { s.model.selectTab(nil) }
        s.model.beginDelete(s.model.spaces[0])
        await pause(0.2)
        await film.shoot("33-delete-category") { s.model.confirmDelete() }
        s.close()
    }

    // Окно панели: таблица кадра и альфы, число раскладок за проход.
    let controller = ClipboardController.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-film-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ClipboardStore(directory: dir, key: SymmetricKey(size: .bits256), limit: 100)
    store.ingest(ClipSnapshot(types: [], text: "запись"))
    controller.attach(store)
    let leave = LeaveStand()
    for pass in ["show", "hide", "show", "hide"] {
        var table = "== панель \(pass)\n"
        let start = ProcessInfo.processInfo.systemUptime
        if pass == "show" { leave.host.present(leave.model) } else { leave.host.hide() }
        table += String(format: "вызов занял %.0f мс\n", (ProcessInfo.processInfo.systemUptime - start) * 1000)
        let layoutsBefore = ClipPanelHostingView.layoutCount
        var y = 0.0, jumps = 0
        for i in 0..<30 {
            await pause(0.012)
            guard let panel = leave.panel else { break }
            let frame = panel.frame
            if i > 0, abs(frame.minY - y) > 14 { jumps += 1 }
            y = frame.minY
            table += String(format: "%5.0f мс  y %7.2f  альфа %.3f  виден %d\n", (ProcessInfo.processInfo.systemUptime - start) * 1000, frame.minY, panel.alphaValue, panel.isVisible ? 1 : 0)
        }
        table += "раскладок NSHostingView за проход: \(ClipPanelHostingView.layoutCount - layoutsBefore), скачков больше 14 pt: \(jumps)\n"
        log += table
        print(table, terminator: "")
        await pause(0.4)
    }
    leave.close()
    controller.detachStore()
    try? log.write(toFile: "\(out)/table.txt", atomically: true, encoding: .utf8)
    exit(0)
}
