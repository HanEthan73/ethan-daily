import SwiftUI

/// 큰 알약 모양 주황 버튼
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .bold))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .foregroundStyle(Theme.ctaInk)
            .background(Capsule().fill(Theme.hi).opacity(configuration.isPressed ? 0.8 : 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}
