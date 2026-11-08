import SwiftUI

/// 스페이스 그레이 금속 알약 버튼
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundStyle(Theme.hiInk)
            .background(Capsule().fill(Theme.metal).opacity(configuration.isPressed ? 0.75 : 1))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(enabled ? 0.22 : 0), radius: 5, y: 2)
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}
