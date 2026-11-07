import AppKit
import SwiftUI

/// Свой значок модуля в строке меню. Настройка `MenuBarIcon.<id>` в общем домене: нет ключа — как было до неё
/// (у утилиты значок есть, пока центр не запущен), `true` — значок есть всегда,
/// `false` — нет никогда. Значок наш и только наш: чужих значков в строке меню мы не трогаем.
enum MenuBarIcon {
    static func key(_ module: Module) -> String { "MenuBarIcon.\(module.rawValue)" }
    /// Куда утилита кладёт просьбу «открой этот модуль» перед тем, как вывести центр вперёд.
    static let openKey = "Hub.OpenModule"

    static func setting(_ module: Module, defaults: UserDefaults = Kit.defaults) -> Bool? {
        defaults.object(forKey: key(module)) as? Bool
    }

    static func set(_ on: Bool, _ module: Module, defaults: UserDefaults = Kit.defaults) {
        defaults.set(on, forKey: key(module))
    }

    /// Снова как до настройки: значка нет. Открепление и удаление снимают ключ, а `false` пишет
    /// только явное «скрыть значок».
    static func clear(_ module: Module, defaults: UserDefaults = Kit.defaults) {
        defaults.removeObject(forKey: key(module))
    }

    /// Больше значков не закрепить: и у центра, и в окне утилиты.
    static let maxPins = 9
    static let limitNotice = "Закреплено девять значков: сначала открепи один"

    /// Переключатель в окнах: включён только явным «да». Пока ключа нет, переключатель выключен у всех, и экраны
    /// не отличаются от прежних.
    static func switchOn(_ setting: Bool?) -> Bool { setting == true }

    /// Рисует ли значок утилита: только закреплённая, открыт центр или нет. Незакреплённая значка не рисует и при
    /// закрытом центре: иначе в строке меню разом появлялись значки всех утилит. `active` — модуль ведёт она.
    static func utilityShows(setting: Bool?, hubRunning: Bool, active: Bool) -> Bool {
        setting == true && (active || !hubRunning)
    }

    /// Нужна ли утилите меню: центр запущен — клик по значку открывает меню, центра нет — окно утилиты, как раньше.
    static func utilityUsesMenu(hubRunning: Bool) -> Bool { hubRunning }

    enum Entry: Equatable {
        case status(String)
        case action(LinkQuickAction)
        case separator
        case open
        case hide
    }

    /// Состав меню значка: строка статуса, быстрые действия, «Открыть в Utilitumus», «Скрыть значок».
    /// Строку статуса модуль отдаёт сам и она не меняется на каждое событие; читается она при открытии меню, а не по таймеру.
    static func entries(status: String, actions: [LinkQuickAction]) -> [Entry] {
        var result: [Entry] = []
        let line = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { result.append(.status(line)) }
        let shown = Array(actions.prefix(4))
        if !shown.isEmpty {
            if !result.isEmpty { result.append(.separator) }
            result += shown.map { .action($0) }
        }
        if !result.isEmpty { result.append(.separator) }
        result += [.open, .hide]
        return result
    }

    /// Просьба центру открыть страницу модуля: ключ в общем домене и вывод центра вперёд. Центр разбирает ключ
    /// только как id известного модуля. `hub` — бандл центра (у утилиты проверенный), nil — центра не найти.
    @MainActor static func requestOpen(_ module: Module, hub: URL?, defaults: UserDefaults = Kit.defaults) {
        defaults.set(module.rawValue, forKey: openKey)
        defaults.synchronize()
        #if !KIT_TEST_DEFAULTS
        guard let hub else { return }
        NSWorkspace.shared.openApplication(at: hub, configuration: NSWorkspace.OpenConfiguration())
        #endif
    }

    /// Прочитать и снять просьбу. Неизвестный id игнорируется.
    static func takeOpenRequest(defaults: UserDefaults = Kit.defaults) -> Module? {
        defaults.synchronize()
        guard let raw = defaults.string(forKey: openKey) else { return nil }
        defaults.removeObject(forKey: openKey)
        return Module(rawValue: raw)
    }
}

/// Значок одного модуля в строке меню. Изображение статичное: что делает модуль, по значку не видно. Меню собирается
/// при открытии (`menuNeedsUpdate`), своих таймеров и подписок нет.
@MainActor
final class MenuBarIconItem: NSObject, NSMenuDelegate {
    struct Content {
        var status: String
        var actions: [LinkQuickAction]
    }

    private let item: NSStatusItem
    private let module: Module
    private let content: () -> Content
    private let perform: (LinkQuickAction) -> Void
    private let open: () -> Void
    private let hide: () -> Void
    private let click: () -> Void
    private let menu = NSMenu()

    /// - Parameters:
    ///   - click: клик, когда меню не нужно (утилита без центра открывает своё окно).
    init(module: Module, content: @escaping () -> Content, perform: @escaping (LinkQuickAction) -> Void,
         open: @escaping () -> Void, hide: @escaping () -> Void, click: @escaping () -> Void = {}) {
        self.module = module
        self.content = content
        self.perform = perform
        self.open = open
        self.hide = hide
        self.click = click
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: module.icon, accessibilityDescription: module.title)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    func setUsesMenu(_ on: Bool) {
        item.menu = on ? menu : nil
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    @objc private func clicked() { click() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = content()
        for entry in MenuBarIcon.entries(status: current.status, actions: current.actions) {
            switch entry {
            case .status(let line):
                let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            case .action(let quick):
                let row = NSMenuItem(title: quick.title, action: #selector(picked(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = ActionBox(quick)
                if let icon = quick.icon { row.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                menu.addItem(row)
            case .separator:
                menu.addItem(.separator())
            case .open:
                let row = NSMenuItem(title: "Открыть в Utilitumus", action: #selector(openPicked), keyEquivalent: "")
                row.target = self
                menu.addItem(row)
            case .hide:
                let row = NSMenuItem(title: "Скрыть значок", action: #selector(hidePicked), keyEquivalent: "")
                row.target = self
                menu.addItem(row)
            }
        }
    }

    private final class ActionBox: NSObject {
        let quick: LinkQuickAction
        init(_ quick: LinkQuickAction) { self.quick = quick }
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let quick = (sender.representedObject as? ActionBox)?.quick else { return }
        if let confirm = quick.confirm, !Self.confirmed(confirm) { return }
        perform(quick)
    }

    @objc private func openPicked() { open() }
    @objc private func hidePicked() { hide() }

    /// Вопрос перед действием: в меню-баре своего диалога нет.
    static func confirmed(_ confirm: LinkConfirm) -> Bool {
        if Kit.standRefuses("вопрос из меню значка") { return false }
        let alert = NSAlert()
        alert.messageText = confirm.title
        alert.informativeText = confirm.message
        alert.addButton(withTitle: confirm.button)
        alert.addButton(withTitle: "Отмена")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Переключатель «Значок в строке меню» в шапке страницы модуля: узкая кнопка со значком, чтобы шапка не стала шире
/// заметно. Размер один при любом состоянии: страница не сдвигается.
struct DSMenuIconSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        DSButton("", icon: "menubar.rectangle", style: isOn ? .secondary : .plain, small: true) { isOn.toggle() }
            .help(isOn ? "Свой значок модуля в строке меню: включён. Нажми, чтобы скрыть" : "Показать свой значок модуля в строке меню")
            .accessibilityLabel("Значок в строке меню")
            .accessibilityValue(isOn ? "включён" : "выключен")
    }
}
