import Foundation
import SwiftUI
import UIKit

enum Fmt {
    static let ko = Locale(identifier: "ko_KR")
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = ko
        c.firstWeekday = 1 // 일요일 시작
        return c
    }()

    static func string(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = ko
        f.dateFormat = format
        return f.string(from: d)
    }
    static func time(_ d: Date) -> String { string(d, "HH:mm") }
    static func short(_ d: Date) -> String { string(d, "M/d (E)") }

    /// 정렬용: 시간 없는 항목은 맨 뒤
    static func minutes(_ d: Date?) -> Int {
        guard let d else { return 24 * 60 }
        let c = cal.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
    static func addDays(_ d: Date, _ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: d) ?? d
    }
    static func daysBetween(_ a: Date, _ b: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }
}

extension Kind {
    var color: Color {
        switch self {
        case .event: return Theme.event
        case .todo: return Theme.todo
        case .memo: return Theme.memo
        }
    }
}

/// 스페이스 그레이 (애플 알루미늄) — 라이트: 스페이스 그레이 포인트, 다크: 실버 포인트
enum Theme {
    static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let hi = adaptive(rgb(0x45464B), rgb(0xD1D1D6))
    static let hiInk = adaptive(.white, rgb(0x151517))
    static let hiSoft = adaptive(rgb(0x45464B, 0.10), rgb(0xD1D1D6, 0.12))
    static let btn = hi
    static let bg = adaptive(rgb(0xE4E5E8), rgb(0x151517))
    static let surface = adaptive(rgb(0xF5F5F7), rgb(0x1E1E21))
    static let line = adaptive(rgb(0xD1D1D6), rgb(0x2F2F33))
    static let event = hi
    static let todo = adaptive(rgb(0x248A3D), rgb(0x30D158))
    static let memo = adaptive(rgb(0xA27B3C), rgb(0xD8B878))
    static let warn = adaptive(rgb(0xE0352B), rgb(0xFF453A))
    static let sun = warn
    /// 알루미늄 금속 느낌 그라데이션 (버튼·선택한 날·일정 막대)
    static let metalTop = adaptive(rgb(0x76777D), rgb(0xF2F2F5))
    static let metalBottom = adaptive(rgb(0x3A3B3F), rgb(0xA4A4AA))
    static var metal: LinearGradient { LinearGradient(colors: [metalTop, metalBottom], startPoint: .top, endPoint: .bottom) }
    /// 진한 바탕 위 글자색 (호환용)
    static let onInk = hiInk
    /// 밀기 색: → 완료 = 초록, ← 일정 등록 = 주황
    static let swipeDone = Color(rgb(0x2FB463))
    static let swipeEvent = Color(rgb(0xFF9500))
}
