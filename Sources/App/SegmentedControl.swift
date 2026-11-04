import AppKit
import SwiftUI

/// Сегменты на NSSegmentedControl вместо `Picker(...).pickerStyle(.segmented)`.
/// У системного SwiftUI-пикера на macOS 26 каждый пересчёт размера создаёт
/// подграф SwiftUI для подписей и оставляет его в памяти: на экране, который
/// обновляется раз в 2–3 секунды, это ~5 МБ в час. Здесь подписи — строки,
/// и пересчёт размера ничего не создаёт.
struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    let items: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    init(_ items: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.items = items
        self._selection = selection
        self.title = title
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        // Сегменты одной ширины — как у SwiftUI-пикера.
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let labels = items.map(title)
        if control.segmentCount != labels.count
            || (0..<labels.count).contains(where: { control.label(forSegment: $0) != labels[$0] }) {
            control.segmentCount = labels.count
            for (i, label) in labels.enumerated() { control.setLabel(label, forSegment: i) }
        }
        let index = items.firstIndex(of: selection) ?? -1
        if control.selectedSegment != index { control.selectedSegment = index }
        control.isEnabled = context.environment.isEnabled
        let size: NSControl.ControlSize = switch context.environment.controlSize {
            case .mini: .mini
            case .small: .small
            case .large, .extraLarge: .large
            default: .regular
        }
        if control.controlSize != size { control.controlSize = size }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: SegmentedControl
        init(_ parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            let i = sender.selectedSegment
            guard parent.items.indices.contains(i) else { return }
            parent.selection = parent.items[i]
        }
    }
}
