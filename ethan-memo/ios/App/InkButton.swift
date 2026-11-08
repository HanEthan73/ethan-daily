import SwiftUI

/// 옵시디언 느낌의 납작한 주황 버튼 (그림자·그라데이션 없음)
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .foregroundStyle(Theme.hiInk)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hi).opacity(configuration.isPressed ? 0.8 : 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}
