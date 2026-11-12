import SwiftUI
import UIKit

/// 좌우로 쓸어 탭 이동. 카드(← 완료 / → 일정 등록)와 달력 칸(좌우 = 달 이동)은 자기 밀기가 따로 있으니
/// 그 위에서 시작한 동작은 탭 이동으로 치지 않음.
enum TabSwipe {
    static let order: [Tab] = [.todo, .calendar, .wiki, .chat]
    fileprivate static let blocks = NSHashTable<UIView>.weakObjects()

    /// 손가락이 닿은 자리(창 기준 좌표)가 탭 이동을 하면 안 되는 곳인가
    static func isBlocked(at p: CGPoint) -> Bool {
        for v in blocks.allObjects where v.window != nil {
            if v.convert(v.bounds, to: nil).contains(p) { return true }
        }
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
              var v = win.hitTest(p, with: nil) else { return false }
        // 글자 입력칸·슬라이더, 가로로 넘기는 목록(사진 줄·표·코드) 위에서는 그쪽 동작이 우선
        while true {
            if v is UITextView || v is UITextField || v is UISlider || v is UISwitch { return true }
            if let s = v as? UIScrollView, s.contentSize.width > s.bounds.width + 4 { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }

    static func neighbor(of t: Tab, _ dir: Int) -> Tab? {
        guard let i = order.firstIndex(of: t) else { return nil }
        let j = i + dir
        return order.indices.contains(j) ? order[j] : nil
    }
}

private final class BlockView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        TabSwipe.blocks.add(self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct BlockMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { BlockView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    /// 이 영역에서 시작한 좌우 밀기는 탭 이동에 쓰지 않음
    func blocksTabSwipe() -> some View { background(BlockMarker()) }
}

extension SyncService {
    /// 당겨서 새로고침: 동기화가 켜져 있으면 지금 맞추고, 위젯도 다시 그림
    func pullRefresh() async {
        let t0 = Date()
        if on { await Task { await run() }.value }   // 화면이 다시 그려져 취소돼도 동기화는 끝까지
        Store.refreshWidgets()
        let rest = 0.6 - Date().timeIntervalSince(t0)
        if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
    }
}
