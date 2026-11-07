import SwiftUI

/// Keep native button focus/press behavior and add an explicit pointer highlight.
private struct HoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(isEnabled && isHovering ? 0.09 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func hoverFeedback(radius: CGFloat = 8) -> some View {
        modifier(HoverFeedback(radius: radius))
    }
}
