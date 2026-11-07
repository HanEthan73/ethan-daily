import Foundation
import SwiftUI

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
        case .event: return .blue
        case .todo: return .green
        case .memo: return .orange
        }
    }
}
