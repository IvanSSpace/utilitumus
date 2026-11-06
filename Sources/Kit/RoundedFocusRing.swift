import SwiftUI

extension View {
    /// Рамка фокуса клавиатуры (Tab) по скруглению кнопки. У кнопок со стилем `.plain`
    /// и своим фоном macOS рисует прямоугольник по краю, и углы торчат; задать ему форму
    /// через contentShape(.focusEffect) не выходит. Поэтому системную рамку выключаем
    /// и рисуем свою — того же цвета и толщины, но по скруглению.
    func roundedFocusRing(_ radius: CGFloat) -> some View {
        modifier(RoundedFocusRing(radius: radius))
    }
}

private struct RoundedFocusRing: ViewModifier {
    let radius: CGFloat
    @FocusState private var focused: Bool
    private let width: CGFloat = 3.5

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: radius + width, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: width)
                    .padding(-width)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}
