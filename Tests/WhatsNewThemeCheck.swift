import AppKit
import SwiftUI

// «Что нового» в «Графите» и в цветных темах: плитки пунктов. Окно за экраном (x: -10000), тексты из настоящего Resources/WhatsNew.json.
// Запуск: Tests/run-whats-new-theme-check.sh. Аргументы: путь к WhatsNew.json, папка PNG.

let jsonURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

let sheetWidth: CGFloat = 500
let sheetHeight: CGFloat = 560
/// Список пунктов: ниже шапки (118) и выбора версии, выше подвала с кнопкой «Понятно», которая красится акцентом системы.
let listTop: CGFloat = 165
let listBottom: CGFloat = 490

@MainActor func snapshot(_ name: String, theme: DSTheme, entries: [WhatsNewEntry]) async -> NSBitmapImageRep {
    let root = ZStack {
        Color(white: 0.12)
        WhatsNewSheet(whatsNew: WhatsNew(entries: entries))
    }
    .environment(\.dsTheme, theme)
    .preferredColorScheme(.dark)
    .frame(width: sheetWidth, height: sheetHeight)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: sheetWidth, height: sheetHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(0.6)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
    return rep
}

/// Сколько пикселей списка заметно цветные (разброс каналов больше 40 из 255) и самый большой разброс.
func colorful(_ rep: NSBitmapImageRep) -> (count: Int, widest: Int) {
    guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return (-1, -1) }
    let scale = CGFloat(rep.pixelsHigh) / sheetHeight
    var count = 0, widest = 0
    for y in Int(listTop * scale)..<Int(listBottom * scale) {
        for x in 0..<rep.pixelsWide {
            let p = data + y * rep.bytesPerRow + x * rep.samplesPerPixel
            let spread = Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2]))
            widest = max(widest, spread)
            if spread > 40 { count += 1 }
        }
    }
    return (count, widest)
}

@MainActor func run() async {
    let entries = try! JSONDecoder().decode([WhatsNewEntry].self, from: Data(contentsOf: jsonURL))
    check(entries.first.map { $0.items.count >= 3 } ?? false, "в WhatsNew.json есть запись с несколькими пунктами")

    let bright: [Color] = [.pink, .orange, .yellow, .green, .teal, .blue, .indigo, .purple]
    check(WhatsNewSheet.tints(for: .graphite).count >= 1 && !WhatsNewSheet.tints(for: .graphite).contains(where: { bright.contains($0) }),
          "Графит: плитки не из яркого списка")
    for theme in [DSTheme.dusk, .calm, .vivid, .midnight, .custom(.dusk)] {
        check(WhatsNewSheet.tints(for: theme) == bright, "\(theme.rawValue): плитки прежние")
    }

    let graphite = colorful(await snapshot("whats-new-graphite", theme: .graphite, entries: entries))
    check(graphite.count == 0, "Графит: в списке «Что нового» нет цветных пикселей (цветных \(graphite.count), разброс до \(graphite.widest))")
    for theme in [DSTheme.dusk, .vivid] {
        let c = colorful(await snapshot("whats-new-\(theme.rawValue)", theme: theme, entries: entries))
        check(c.count > 500, "\(theme.rawValue): плитки цветные (цветных пикселей \(c.count), разброс до \(c.widest))")
    }
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
