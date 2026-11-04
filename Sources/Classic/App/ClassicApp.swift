import SwiftUI

/// Классический интерфейс: обычное окно с заголовком и панелью инструментов, как до редизайна.
struct ClassicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Utilitumus", id: "main") {
            ClassicMainView()
        }
        .defaultSize(width: 760, height: 560)
        .commands { AppCommands() }
    }
}
