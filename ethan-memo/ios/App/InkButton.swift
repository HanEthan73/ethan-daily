import SwiftUI

/// 검정(다크 모드는 흰색) 알약 버튼
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(Theme.onInk)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.7 : 1)))
            .opacity(enabled ? 1 : 0.35)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}
