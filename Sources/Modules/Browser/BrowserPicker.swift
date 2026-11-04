import SwiftUI
import AppKit

// MARK: - Модель

/// Состояние панели выбора: что за ссылка, из чего выбирать, что выделено.
@MainActor
final class BrowserPickerModel: ObservableObject {
    let url: URL
    let sourceName: String?
    let sourceIcon: NSImage?
    let browsers: [InstalledBrowser]
    /// Клавиши браузеров (bundle id → keyCode), уже с учётом автоматических.
    let keys: [String: UInt16]
    @Published var selected: Int
    /// Зажат ⌥: открыть в приватном окне.
    @Published var optionHeld: Bool
    /// Галочка «Запомнить для домена» (то же делает ⇧ при выборе).
    @Published var remember = false

    init(url: URL, source: NSRunningApplication?, browsers: [InstalledBrowser], keys: [String: UInt16], preselected: String?) {
        self.url = url
        sourceName = source?.localizedName
        sourceIcon = source?.icon
        self.browsers = browsers
        self.keys = keys
        selected = browsers.firstIndex { $0.id == preselected } ?? 0
        optionHeld = NSEvent.modifierFlags.contains(.option)
    }

    /// Хост, на который можно повесить правило. У файла и ссылки без хоста его нет.
    var rememberDomain: String? {
        BrowserRuleMatcher.host(of: url).flatMap(BrowserRuleMatcher.normalizeDomain)
    }

    /// Заголовок: домен, а для файла — его имя.
    var title: String {
        if url.isFileURL { return url.lastPathComponent }
        return BrowserRuleMatcher.host(of: url) ?? url.absoluteString
    }

    var fullLink: String { url.isFileURL ? url.path : url.absoluteString }
}

// MARK: - Вид

/// Содержимое панели: вертикальный список браузеров, под ним домен, источник и «Запомнить».
struct BrowserPickerView: View {
    @ObservedObject var model: BrowserPickerModel
    let choose: (Int, NSEvent.ModifierFlags) -> Void

    static let width: CGFloat = 272
    static let rowHeight: CGFloat = 38
    /// Больше строк — список прокручивается, высота панели ограничена.
    static let maxVisibleRows = 6

    private var scrolls: Bool { model.browsers.count > Self.maxVisibleRows }

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider().padding(.horizontal, 12).padding(.top, 4)
            footer
        }
        .frame(width: Self.width)
        .focusEffectDisabled()
    }

    private var list: some View {
        let rows = VStack(spacing: 2) {
            ForEach(Array(model.browsers.enumerated()), id: \.element.id) { index, browser in
                BrowserPickerRow(browser: browser, index: index, model: model) {
                    choose(index, NSEvent.modifierFlags)
                }
                .id(index)
            }
        }
        .padding(8)
        return Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .frame(height: CGFloat(Self.maxVisibleRows) * (Self.rowHeight + 2) + 16)
                        .onChange(of: model.selected) { _, new in proxy.scrollTo(new) }
                }
            } else {
                rows
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(model.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.fullLink)
            if let name = model.sourceName {
                HStack(spacing: 4) {
                    if let icon = model.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text("из \(name)").lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Приложение, из которого пришла ссылка")
            }
            HStack(spacing: 8) {
                if let domain = model.rememberDomain {
                    Toggle(isOn: $model.remember) {
                        Text("Запомнить для \(domain)").lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Дальше ссылки с этого сайта сразу открываются в выбранном браузере (то же делает ⇧ при выборе)")
                }
                Spacer(minLength: 0)
                if model.optionHeld {
                    Label("Приватно", systemImage: "eyeglasses")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// Строка списка: имя слева, справа цифра-хоткей в рамке и иконка. Выбранная залита акцентом.
private struct BrowserPickerRow: View {
    let browser: InstalledBrowser
    let index: Int
    @ObservedObject var model: BrowserPickerModel
    let action: () -> Void

    private var isSelected: Bool { model.selected == index }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(browser.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if model.optionHeld && browser.supportsPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 8)
                if let label = model.keys[browser.id].flatMap(BrowserKeys.label(for:)) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? Color.white.opacity(0.8) : Color.primary.opacity(0.3), lineWidth: 1)
                        )
                }
                Image(nsImage: browser.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: BrowserPickerView.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Выделение — только скруглённая заливка: системное кольцо фокуса даёт прямоугольный контур.
        .focusEffectDisabled()
        .onHover { if $0 { model.selected = index } }
    }
}

// MARK: - Панель

/// Не активирует Utilitumus, но принимает клавиатуру. Закрывается, когда теряет фокус.
final class BrowserPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // Неотработанные клавиши глотаем: системный «бип» на каждый символ ни к чему.
        _ = onKeyDown?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘C приходит сюда раньше, чем в главное меню.
        if event.type == .keyDown, onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        onFlagsChanged?(event.modifierFlags)
    }

    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Панель выбора браузера у курсора. Одна на приложение: новая ссылка заменяет содержимое.
@MainActor
final class BrowserPicker {
    static let shared = BrowserPicker()

    private var panel: BrowserPanel?
    private var model: BrowserPickerModel?
    private var onChoose: ((InstalledBrowser, Bool, Bool) -> Void)?
    private var mouseMonitor: Any?

    var isShown: Bool { panel?.isVisible == true }
    /// Панель закрылась (выбором или отменой). Помощник прячется, чтобы фокус вернулся туда, где кликнули.
    var onDismiss: (() -> Void)?

    /// Расположение: по центру курсора, чуть ниже него; не помещается — выше. Всегда внутри экрана.
    static func origin(cursor: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let margin: CGFloat = 8, gap: CGFloat = 14
        var x = cursor.x - size.width / 2
        var y = cursor.y - gap - size.height
        if y < visible.minY + margin { y = cursor.y + gap }
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return CGPoint(x: x, y: y)
    }

    func show(url: URL, source: NSRunningApplication?, browsers: [InstalledBrowser], keys: [String: UInt16],
              preselected: String?,
              onChoose: @escaping (InstalledBrowser, Bool, Bool) -> Void) {
        let model = BrowserPickerModel(url: url, source: source, browsers: browsers, keys: keys, preselected: preselected)
        self.model = model
        self.onChoose = onChoose

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: BrowserPickerView(model: model) { [weak self] index, flags in
            self?.choose(index, flags: flags)
        })
        // Содержимое меняем целиком: размер зависит от числа браузеров и ссылки.
        let effect = panel.contentView as! NSVisualEffectView
        effect.subviews.forEach { $0.removeFromSuperview() }
        host.translatesAutoresizingMaskIntoConstraints = false
        host.focusRingType = .none
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var size = host.fittingSize
        size.width = min(size.width, visible.width - 16)
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(cursor: cursor, size: size, visible: visible))

        panel.onKeyDown = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
        panel.onFlagsChanged = { [weak model] flags in
            MainActor.assumeIsolated { model?.optionHeld = flags.contains(.option) }
        }
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMouseMonitor()
    }

    func close() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        // Сначала сбрасываем колбэки: orderOut тоже может вызвать resignKey.
        panel?.onResignKey = nil
        let wasShown = panel?.isVisible == true
        panel?.orderOut(nil)
        model = nil
        onChoose = nil
        if wasShown { onDismiss?() }
    }

    /// Клик в другом приложении ключевого окна не отнимает (Utilitumus не активен) — ловим его отдельно.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func choose(_ index: Int, flags: NSEvent.ModifierFlags) {
        guard let model, let onChoose, model.browsers.indices.contains(index) else { return }
        let browser = model.browsers[index]
        let isPrivate = flags.contains(.option) && browser.supportsPrivate
        let remember = model.remember || flags.contains(.shift)
        close()
        onChoose(browser, isPrivate, remember)
    }

    /// Клавиши браузеров, стрелки вверх и вниз, Enter, Esc, ⌘C. Остальное глотаем.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            // ⌘C по физической клавише: с русской раскладкой символ другой.
            if event.keyCode == 8 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.fullLink, forType: .string)
                close()
                return true
            }
            return false
        }
        let count = model.browsers.count
        switch event.keyCode {
        case 53:
            close()
        case 126:
            model.selected = (model.selected - 1 + count) % count
        case 125:
            model.selected = (model.selected + 1) % count
        case 36, 76:
            choose(model.selected, flags: flags)
        default:
            // Сравниваем по физической клавише: на русской раскладке «C» остаётся клавишей C.
            let code = BrowserKeys.normalized(event.keyCode)
            if let index = model.browsers.firstIndex(where: { model.keys[$0.id] == code }) {
                choose(index, flags: flags)
            }
        }
        return true
    }

    private func makePanel() -> BrowserPanel {
        let panel = BrowserPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 140),
                                 styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.focusRingType = .none
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect
        return panel
    }
}
