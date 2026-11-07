import SwiftUI
import AppKit
import os

/// Что происходит с переносом на настоящем сеансе: проверка его не видит. Только места и признаки, без содержимого записей.
/// Смотреть: `log stream --info --predicate 'subsystem == "local.utilitumus.clipboard"'`.
enum ClipDragLog {
    static let log = Logger(subsystem: "local.utilitumus.clipboard", category: "drag")
}

/// Все движения панели, одна таблица. Образец — `SidebarMotion` лаунчера: «Уменьшение движения» убирает их, всё встаёт сразу.
/// Анимация идёт только там, где движется конкретный элемент. Смена вкладки, фильтра, выбора и поиска её не включают.
enum ClipMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Перемещение: соседи при переносе, смыкание после снятия и удаления. Пружина без отскока.
    static let moveTime = 0.2
    static var move: Animation? { reduced ? nil : .smooth(duration: moveTime) }
    /// Затухание: содержимое вкладки и фильтра, подсветка категории, прокрутка стрелками.
    static let fadeTime = 0.12
    static var fade: Animation? { reduced ? nil : .easeOut(duration: fadeTime) }
    /// Вспышка при посадке на категорию, единственное место с лёгким отскоком.
    static var flash: Animation? { reduced ? nil : .spring(response: 0.18, dampingFraction: 0.7) }
    /// Сколько вспышка держится, прежде чем погаснуть.
    static let flashHold = 0.1
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
        withAnimation(ClipMotion.fade) { hovered = true }
    }

    func dropExited(info: DropInfo) {
        if carriesSpace(info) { return }
        withAnimation(ClipMotion.fade) { hovered = false }
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
            withAnimation(ClipMotion.fade) { hovered = false }
            return false
        }
        withAnimation(ClipMotion.flash) {
            hovered = false
            flashing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipMotion.flashHold) {
            withAnimation(ClipMotion.fade) { flashing = false }
        }
        return true
    }
}

/// Вид категории под переносом: и вкладка с названием, и точка на время поиска. Состояние своё: ряд и карточки не перерисовываются.
/// Масштаб только во вспышке и не меняет раскладку: соседние категории стоят на месте.
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
        return flashing ? 1.06 : 1
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
