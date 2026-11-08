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

/// 블랙·그레이 톤
enum Theme {
    static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let event = adaptive(UIColor(white: 0.23, alpha: 1), UIColor(white: 0.79, alpha: 1))
    static let todo = adaptive(UIColor(red: 0.37, green: 0.42, blue: 0.40, alpha: 1), UIColor(red: 0.62, green: 0.68, blue: 0.65, alpha: 1))
    static let memo = adaptive(UIColor(red: 0.55, green: 0.50, blue: 0.42, alpha: 1), UIColor(red: 0.73, green: 0.68, blue: 0.60, alpha: 1))
    static let warn = adaptive(UIColor(red: 0.71, green: 0.33, blue: 0.16, alpha: 1), UIColor(red: 0.88, green: 0.55, blue: 0.39, alpha: 1))
    static let sun = adaptive(UIColor(red: 0.76, green: 0.27, blue: 0.25, alpha: 1), UIColor(red: 0.88, green: 0.48, blue: 0.45, alpha: 1))
    /// 검정(라이트)·흰색(다크) 바탕 위 글자색
    static let onInk = Color(UIColor.systemBackground)
    /// 밀기 버튼 배경 (흰 글자가 잘 보이는 중간 톤)
    static let swipeDone = Color(red: 0.36, green: 0.44, blue: 0.40)
    static let swipeEvent = Color(white: 0.33)
}
