import SwiftUI
import AppKit
import os

/// Движение панели. Образец — `SidebarMotion` лаунчера: «Уменьшение движения» убирает пружину, всё встаёт сразу.
/// Что происходит с переносом на настоящем сеансе: проверка его не видит. Только места и признаки, без содержимого записей.
/// Смотреть: `log stream --info --predicate 'subsystem == "local.utilitumus.clipboard"'`.
enum ClipDragLog {
    static let log = Logger(subsystem: "local.utilitumus.clipboard", category: "drag")
}

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
    /// Несут саму категорию: другое дело, порядок ряда, а не закрепление. Место считает модель по курсору, как у карточек.
    let model: ClipboardPanelModel
    let accept: ([NSItemProvider]) -> Bool

    private func carriesSpace(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [ClipDrag.spaceType]) }

    func validateDrop(info: DropInfo) -> Bool {
        carriesSpace(info) ? model.canReorderSpaces : info.hasItemsConforming(to: [ClipDrag.recordType])
    }

    func dropEntered(info: DropInfo) {
        if carriesSpace(info) { return }
        withAnimation(ClipMotion.hover) { hovered = true }
    }

    func dropExited(info: DropInfo) {
        if carriesSpace(info) { return }
        withAnimation(ClipMotion.hover) { hovered = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if carriesSpace(info) { model.dragTick() }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if carriesSpace(info) {
            guard model.draggedSpace != nil else { return false }
            model.finishDrag()
            return true
        }
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
    let reach: CGFloat
    let model: ClipboardPanelModel
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
            .padding(.horizontal, reach)
            .onDrop(of: [ClipDrag.recordType, ClipDrag.spaceType],
                    delegate: ClipSpaceDropDelegate(hovered: $hovered, flashing: $flashing, model: model, accept: accept))
            .padding(.horizontal, -reach)
    }
}

/// Приёмник карточки во вкладке категории. Только говорит системе «сюда можно», без значка «+» и без возврата копии на место.
/// Само место считает модель по курсору, см. `dragTick`.
struct ClipCardDropDelegate: DropDelegate {
    let model: ClipboardPanelModel

    func validateDrop(info: DropInfo) -> Bool {
        model.canReorderRecords && info.hasItemsConforming(to: [ClipDrag.recordType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.dragTick()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard model.draggedRecord != nil else { return false }
        model.finishDrag()
        return true
    }
}
