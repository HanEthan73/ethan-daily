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

/// macOS 캘린더 느낌: 흰 카드 + 형광펜 색 + 스페이스 그레이 버튼
enum Theme {
    static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let hi = adaptive(rgb(0xE86F00), rgb(0xFFA526))
    static let hiInk = Color.white
    static let hiSoft = adaptive(rgb(0xFF9500, 0.14), rgb(0xFF9F0A, 0.18))
    static let btn = hi
    static let bg = adaptive(rgb(0xF2F2F7), rgb(0x000000))
    static let surface = adaptive(rgb(0xFFFFFF), rgb(0x1C1C1E))
    static let line = adaptive(rgb(0xE3E3E8), rgb(0x38383A))
    static let today = adaptive(rgb(0xFF8A00), rgb(0xFF9500))
    static let event = adaptive(rgb(0x007AFF), rgb(0x0A84FF))
    static let todo = adaptive(rgb(0xF27A00), rgb(0xFF9F0A))
    static let memo = adaptive(rgb(0xC28A00), rgb(0xFFD60A))
    static let warn = adaptive(rgb(0xE5352B), rgb(0xFF453A))
    static let sun = warn
    /// 연그레이 3D 카드
    static let cardTop = adaptive(rgb(0xFFFFFF), rgb(0xF2F2F5))
    static let cardBottom = adaptive(rgb(0xECECF0), rgb(0xD9D9DE))
    static let cardLip = adaptive(rgb(0xC9C9CF), rgb(0x8E8E95))
    static let cardInk = Color(rgb(0x141416))
    static let cardSub = Color(rgb(0x55555B))
    /// 포스트잇 바탕
    static let noteTodo = adaptive(rgb(0xFFF3E3), rgb(0x35261A))
    static let noteMemo = adaptive(rgb(0xFFF9D9), rgb(0x302A17))
    static let noteDone = adaptive(rgb(0xF4F4F6), rgb(0x1F1F21))
    static let noteLate = adaptive(rgb(0xFFECEA), rgb(0x2E1C1B))
    static let metalTop = adaptive(rgb(0xFFA83D), rgb(0xFFAE45))
    static let metalBottom = adaptive(rgb(0xF27500), rgb(0xF07400))
    static var metal: LinearGradient { LinearGradient(colors: [metalTop, metalBottom], startPoint: .top, endPoint: .bottom) }
    static let onInk = hiInk
    /// 밀기 색: ← 완료 = 초록, → 일정 등록 = 주황
    static let swipeDone = Color(rgb(0x2FB463))
    static let swipeEvent = Color(rgb(0xFF9500))

    /// 형광펜 색 (선 c · 글자 t · 바탕 b) — 웹과 같은 규칙으로 일정마다 색이 정해짐
    struct HL { let c: Color; let t: Color; let b: Color }
    private static let palette: [(UInt32, UInt32, UInt32, CGFloat, UInt32, CGFloat)] = [
        // 선, 라이트 글자, 다크 글자, 라이트 바탕 투명도, 다크 바탕색, 다크 투명도
        (0x007AFF, 0x0A5BC4, 0x5EAEFF, 0.15, 0x0A84FF, 0.26),
        (0xFF3B30, 0xC42B23, 0xFF7A72, 0.14, 0xFF453A, 0.24),
        (0xFFCC00, 0x8A6500, 0xFFD60A, 0.30, 0xFFD60A, 0.20),
        (0x34C759, 0x1B7D3A, 0x4FE07A, 0.18, 0x30D158, 0.22),
        (0xAF52DE, 0x8A33B5, 0xD99BFF, 0.15, 0xBF5AF2, 0.25),
        (0xFF9500, 0xB05F00, 0xFFB340, 0.18, 0xFF9F0A, 0.22),
        (0x30B0C7, 0x13788A, 0x64D2E6, 0.17, 0x64D2FF, 0.20),
    ]
    static func hl(_ key: String) -> HL {
        var n: UInt32 = 0
        for u in key.utf16 { n = n &* 31 &+ UInt32(u) }
        let p = palette[Int(n % UInt32(palette.count))]
        return HL(c: Color(rgb(p.0)),
                  t: adaptive(rgb(p.1), rgb(p.2)),
                  b: adaptive(rgb(p.0, p.3), rgb(p.4, p.5)))
    }
}
