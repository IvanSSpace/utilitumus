import SwiftUI
import AppKit

/// Что показывает плашка внизу экрана.
@MainActor
final class VoiceHUDModel: ObservableObject {
    enum Kind: Equatable {
        case listening
        case transcribing
        case message(String, isError: Bool)
    }

    @Published var kind: Kind = .listening
    /// Громкость 0...1.
    @Published var level: Float = 0
}

struct VoiceHUDView: View {
    @ObservedObject var model: VoiceHUDModel

    static let size = CGSize(width: 300, height: 48)

    var body: some View {
        HStack(spacing: 10) {
            switch model.kind {
            case .listening:
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Слушаю…")
                levelBar
                Text("Esc — отмена").font(.caption).foregroundStyle(.secondary)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Распознаю…")
                Spacer(minLength: 0)
                Text("Esc — отмена").font(.caption).foregroundStyle(.secondary)
            case let .message(text, isError):
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.orange : Color.green)
                Text(text).lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.green)
                    .frame(width: max(4, geo.size.width * CGFloat(model.level)))
            }
        }
        .frame(height: 6)
    }
}

/// Плашка, которая не забирает фокус: окно, куда диктуешь, остаётся активным.
private final class VoiceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VoiceHUD {
    static let shared = VoiceHUD()

    let model = VoiceHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func showListening() {
        present(.listening)
    }

    func showTranscribing() {
        present(.transcribing)
    }

    /// Короткое сообщение: гаснет само.
    func showMessage(_ text: String, isError: Bool = false, seconds: Double = 2.5) {
        present(.message(text, isError: isError))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func present(_ kind: VoiceHUDModel.Kind) {
        hideTask?.cancel()
        hideTask = nil
        model.kind = kind
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Внизу по центру экрана, где сейчас курсор.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = VoiceHUDView.size
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 72,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = VoiceHUDPanel(contentRect: CGRect(origin: .zero, size: VoiceHUDView.size),
                                  styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        let host = NSHostingView(rootView: VoiceHUDView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }
}
