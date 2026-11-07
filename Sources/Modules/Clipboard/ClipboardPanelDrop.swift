import SwiftUI
import AppKit

/// Движение панели. Образец — `SidebarMotion` лаунчера: «Уменьшение движения» убирает пружину, всё встаёт сразу.
enum ClipMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Наведение на категорию и возврат.
    static var hover: Animation? { reduced ? nil : .spring(response: 0.26, dampingFraction: 0.68) }
    /// Вспышка при посадке: быстрее наведения и с отскоком.
    static var landing: Animation? { reduced ? nil : .spring(response: 0.2, dampingFraction: 0.5) }
    /// Сколько вспышка держится, прежде чем погаснуть: столько нужно пружине, чтобы дойти до пика.
    static let flashHold = 0.18
    /// Точка на карточке и смыкание соседних карточек.
    static var settle: Animation? { reduced ? nil : .spring(response: 0.34, dampingFraction: 0.84) }
}

/// Приёмник карточки на категории. `.move` вместо копирования: у своего типа над категорией нет значка «+».
/// Предложение относится только к этому приёмнику: что программы получают при выносе наружу, решает `ClipDrag.provider`.
struct ClipSpaceDropDelegate: DropDelegate {
    @Binding var hovered: Bool
    @Binding var flashing: Bool
    let accept: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ClipDrag.recordType]) }

    func dropEntered(info: DropInfo) {
        withAnimation(ClipMotion.hover) { hovered = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(ClipMotion.hover) { hovered = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard accept(info.itemProviders(for: [ClipDrag.recordType])) else {
            withAnimation(ClipMotion.hover) { hovered = false }
            return false
        }
        withAnimation(ClipMotion.landing) {
            hovered = false
            flashing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipMotion.flashHold) {
            withAnimation(ClipMotion.hover) { flashing = false }
        }
        return true
    }
}

/// Вид категории под переносом: и вкладка с названием, и точка на время поиска. Состояние своё: ряд и карточки не перерисовываются.
/// Масштаб не меняет раскладку: соседние категории стоят на месте, а цель броска не дрожит под курсором.
struct ClipSpaceDropEffect: ViewModifier {
    let color: Color
    let accept: ([NSItemProvider]) -> Bool
    @State private var hovered = false
    @State private var flashing = false

    private var fill: Double { flashing ? 0.8 : hovered ? 0.32 : 0 }
    private var scale: CGFloat {
        if ClipMotion.reduced { return 1 }
        return flashing ? 1.12 : hovered ? 1.06 : 1
    }

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(fill)))
            .scaleEffect(scale)
            .onDrop(of: [ClipDrag.recordType],
                    delegate: ClipSpaceDropDelegate(hovered: $hovered, flashing: $flashing, accept: accept))
    }
}
