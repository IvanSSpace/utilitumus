import AppKit
import Combine
import SwiftUI

/// Мини-плеер: маленькая плавающая панель на время чтения (фаза «читаю» или «пауза»), с паузой, скоростью и стопом.
/// Фокус не забирает: программа, где выделен текст, остаётся активной. Текста чтения в панели нет, только фаза и скорость.
@MainActor
final class SpeakPlayer {
    private let controller: SpeakController
    private var panel: NSPanel?
    private var phaseSub: AnyCancellable?
    /// Панель сейчас должна быть на экране. Стенд её не показывает, но решение видно и ему.
    private(set) var visible = false

    /// Ничего не показывает и не подписывается: работа только после `attach`.
    init(controller: SpeakController) {
        self.controller = controller
    }

    /// Модуль запущен: панель идёт за фазой чтения.
    func attach() {
        guard phaseSub == nil else { return }
        phaseSub = controller.$phase.removeDuplicates().sink { [weak self] phase in self?.apply(phase) }
    }

    /// Модуль остановлен: отписаться и убрать панель. Повторный вызов безвреден.
    func detach() {
        phaseSub = nil
        hide()
    }

    private func apply(_ phase: SpeakPhase) {
        switch phase {
        case .idle: hide()
        // Между «читаю» и «пауза» панель стоит на месте: её место выбрано при начале чтения.
        case .speaking, .paused: if !visible { show() }
        }
    }

    private func show() {
        visible = true
        if Kit.standRefuses("панель озвучки") { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = SpeakPlayerView<SpeakController>.size
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        let origin = Self.origin(size: size, cursor: NSEvent.mouseLocation, screens: screens, main: NSScreen.main?.visibleFrame)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        visible = false
        panel?.orderOut(nil)
    }

    /// Отступ от курсора и от краёв видимой области.
    static let cursorGap: CGFloat = 14
    static let edgeGap: CGFloat = 8

    /// Где поставить панель: справа снизу от курсора и целиком на его экране (у нижнего края — над курсором).
    /// Курсор ни на одном экране — правый верхний угол видимой области главного экрана. Координаты экрана, начало внизу слева.
    static func origin(size: CGSize, cursor: CGPoint, screens: [(frame: CGRect, visible: CGRect)], main: CGRect?) -> CGPoint {
        guard let area = screens.first(where: { $0.frame.contains(cursor) })?.visible else {
            guard let main else { return .zero }
            return CGPoint(x: main.maxX - size.width - edgeGap * 2, y: main.maxY - size.height - edgeGap * 2)
        }
        var y = cursor.y - cursorGap - size.height
        if y < area.minY + edgeGap { y = cursor.y + cursorGap }
        let x = cursor.x + cursorGap
        return CGPoint(x: clamp(x, area.minX + edgeGap, area.maxX - size.width - edgeGap),
                       y: clamp(y, area.minY + edgeGap, area.maxY - size.height - edgeGap))
    }

    /// Область уже панели — к левому (нижнему) краю.
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }

    private func makePanel() -> NSPanel {
        let size = SpeakPlayerView<SpeakController>.size
        let panel = SpeakPlayerWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        // На всех пространствах и поверх полноэкранных; в Mission Control и в переборе окон по ⌘` её нет.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Тема из настроек, как у экрана.
        let host = SpeakPlayerHostingView(rootView: SpeakPlayerView(model: controller).dsThemed())
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }
}

/// Панель, которая не становится ключевой: клик по кнопке не уводит фокус из программы, где выделен текст.
private final class SpeakPlayerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Окно не ключевое: без этого первый клик только «будил» бы его, а не нажимал кнопку.
private final class SpeakPlayerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Вид панели. Только фаза и скорость: что читается, здесь не видно.
struct SpeakPlayerView<Model: SpeakModel>: View {
    @ObservedObject var model: Model
    @Environment(\.dsTheme) private var theme

    static var size: CGSize { CGSize(width: 330, height: 46) }

    private var paused: Bool { model.phase == .paused }

    var body: some View {
        let tint = theme.accent(.speak)
        HStack(spacing: 6) {
            Image(systemName: paused ? "pause.circle.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 20)
            Text(paused ? "Пауза" : "Читаю…")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            SpeakPlayerButton(icon: paused ? "play.fill" : "pause.fill", help: paused ? "Продолжить" : "Пауза") {
                if paused { model.resume() } else { model.pause() }
            }
            divider
            SpeakPlayerButton(icon: "minus", help: "Медленнее") { model.stepSpeed(-1) }
                .disabled(model.speed <= SpeakSpeed.range.lowerBound)
            Text(SpeakSpeed.label(model.speed))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                .frame(width: 38)
            SpeakPlayerButton(icon: "plus", help: "Быстрее") { model.stepSpeed(1) }
                .disabled(model.speed >= SpeakSpeed.range.upperBound)
            divider
            SpeakPlayerButton(icon: "stop.fill", help: "Остановить") { model.stopSpeaking() }
        }
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: theme.background(.speak), startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.dsTint, tint)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 2)
    }
}

/// Круглая кнопка-значок панели.
private struct SpeakPlayerButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .hoverFill(Circle(), normal: .white.opacity(0.1), hovered: .white.opacity(0.18))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}
