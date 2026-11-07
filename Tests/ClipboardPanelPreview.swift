import AppKit
import SwiftUI

// Показ панели автору: настоящая панель, выдуманные записи. Собирает Tests/preview-clipboard-panel.sh.
// Контроллера и хранилища здесь нет, поэтому нет истории, ключа, горячей клавиши и слежения за буфером; всё живёт в памяти.
// «Вставка» только пишет на экране, что вставила бы: системный буфер не трогается, ⌘V не шлётся.

@MainActor
enum PreviewNote {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    /// Надпись над панелью. Своя панель: плашка выпуска осталась бы ниже уровня панели.
    static func show(_ text: String) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let size = NSSize(width: 520, height: 44)
        let area = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + ClipPanelMetrics.panelHeight + 14,
                           width: size.width, height: size.height)
        let note = panel ?? {
            let made = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            made.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.ignoresMouseEvents = true
            made.isReleasedWhenClosed = false
            return made
        }()
        panel = note
        note.contentView = NSHostingView(rootView: Text(text)
            .font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 16)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.85))))
        note.setFrame(frame, display: true)
        note.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { note.orderOut(nil) } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

@main
enum PreviewApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = ClipboardPanelModel()
        model.allItems = ClipPanelFixture.items()
        model.spaces = ClipPanelFixture.spaces
        model.imageLoader = ClipPanelFixture.image
        // Перенос наружу несёт выдуманное: нарисованный PNG и выдуманный файл во временной папке показа.
        model.imageBytes = { item in { ClipPanelFixture.png(item) } }
        let files = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clipboard-panel-preview-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for index in model.allItems.indices where model.allItems[index].kind == .file {
            model.allItems[index].filePaths = model.allItems[index].filePaths?.map { path in
                let file = files.appendingPathComponent((path as NSString).lastPathComponent)
                try? Data("Выдуманный файл из показа панели.\n".utf8).write(to: file)
                return file.path
            }
        }
        model.onPaste = { item in
            let what = item.text ?? item.filePaths?.first ?? item.kind.title
            PreviewNote.show("Вставил бы: " + what.replacingOccurrences(of: "\n", with: " "))
        }
        model.onPin = { [weak model] id, space in
            guard let model, let index = model.allItems.firstIndex(where: { $0.id == id }) else { return }
            model.allItems[index].spaceID = space
        }
        model.onDelete = { [weak model] id in
            guard let model else { return }
            model.allItems.removeAll { $0.id == id }
            model.selected = min(model.selected, max(0, model.visible.count - 1))
        }
        model.onAddSpace = { [weak model] name, color, hidden in
            model?.spaces.append(ClipSpace(id: UUID(), name: name, colorID: color, hidesContent: hidden ? true : nil))
        }
        model.onSetSpaceHidden = { [weak model] id, hidden in
            guard let model, let index = model.spaces.firstIndex(where: { $0.id == id }) else { return }
            model.spaces[index].hidesContent = hidden ? true : nil
        }
        model.onSetTitle = { [weak model] id, title in
            guard let model, let index = model.allItems.firstIndex(where: { $0.id == id }) else { return }
            model.allItems[index].title = title
        }
        model.onMoveSpace = { [weak model] id, position in
            guard let model else { return }
            let moved = ClipReorder.moved(model.spaces.map(\.id), id, to: position)
            model.spaces = moved.compactMap { id in model.spaces.first { $0.id == id } }
        }
        model.onMoveRecord = { [weak model] id, position in
            guard let model, let space = model.allItems.first(where: { $0.id == id })?.spaceID else { return }
            let order = ClipboardStore.filter(model.allItems, space: space, query: "", spaces: []).map(\.id)
            let moved = ClipReorder.moved(order, id, to: position)
            for index in model.allItems.indices where model.allItems[index].spaceID == space {
                model.allItems[index].spaceRank = moved.firstIndex(of: model.allItems[index].id)
            }
        }
        model.onRenameSpace = { [weak model] id, name in
            guard let model, let index = model.spaces.firstIndex(where: { $0.id == id }) else { return }
            model.spaces[index].name = name
        }
        model.onSetSpaceColor = { [weak model] id, color in
            guard let model, let index = model.spaces.firstIndex(where: { $0.id == id }) else { return }
            model.spaces[index].colorID = color
        }
        model.onDeleteSpace = { [weak model] id in
            guard let model else { return }
            model.spaces.removeAll { $0.id == id }
            for index in model.allItems.indices where model.allItems[index].spaceID == id { model.allItems[index].spaceID = nil }
        }
        model.onOpenSettings = { PreviewNote.show("Открыл бы настройки Буфера") }
        let host = ClipboardPanelHost.shared
        // Esc без поиска и окошка закрывает панель с настоящей анимацией: здесь вернуть её нечем, поэтому затем показ завершается.
        model.onClose = { host.hide { NSApp.terminate(nil) } }
        host.hidesOnOutsideClick = false
        let panel = host.present(model)
        // Автор может снять экран: записи выдуманные.
        panel.sharingType = .readOnly
        // Тема из аргумента, настройки не трогаем: graphite, dusk, calm, vivid, midnight.
        if let raw = CommandLine.arguments.dropFirst().first, let theme = DSTheme(rawValue: raw) {
            model.theme = theme
        } else {
            model.theme = .vivid
        }
        app.run()
    }
}
