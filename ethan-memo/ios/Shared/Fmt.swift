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
    // 강조색·지난 일 색은 설정에서 바꿀 수 있음 (앱 그룹에 저장 → 위젯도 같이 따라감)
    static var hi: Color { ThemePrefs.accent }
    static let hiInk = adaptive(rgb(0xFFFFFF), rgb(0x1B1204))
    static var hiSoft: Color { ThemePrefs.accentSoft }
    static var btn: Color { hi }
    static let bg = adaptive(rgb(0xF5F4F8), rgb(0x0B0B0E))
    static let surface = adaptive(rgb(0xFFFFFF), rgb(0x17171B))
    static let line = adaptive(rgb(0xE2E0E8), rgb(0x2B2B31))
    static var today: Color { hi }
    static let event = adaptive(rgb(0x007AFF), rgb(0x0A84FF))
    static var todo: Color { hi }
    static let memo = adaptive(rgb(0xC28A00), rgb(0xFFD60A))
    /// 지난 일 색 (기본: 눈이 덜 아픈 코랄)
    static var warn: Color { ThemePrefs.late }
    static let sun = adaptive(rgb(0xE5352B), rgb(0xFF453A))
    /// 연그레이 3D 카드
    static let cardTop = adaptive(rgb(0xECEAF1), rgb(0x1D1D22))
    static let cardBottom = cardTop
    static let cardLip = adaptive(rgb(0x3C3C50, 0.16), rgb(0x000000, 0.55))
    static let cardHi = adaptive(rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.09))
    static let cardShadow = adaptive(rgb(0x28284A, 0.24), rgb(0x000000, 0.65))
    static let cardInk = adaptive(rgb(0x1C1C1E), rgb(0xF4F4F7))
    static let cardSub = adaptive(rgb(0x6A6A72), rgb(0x9C9CA5))
    /// 알약 바탕 (YouTube Premium 느낌의 둥근 행)
    static let pill = cardTop
    static let pillHi = adaptive(rgb(0xE2E0EA), rgb(0x27272D))
    /// 주황 버튼 글자: 어두운 모드는 짙은 갈색, 밝은 모드는 흰색
    static let ctaInk = adaptive(rgb(0xFFFFFF), rgb(0x1B1204))
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

/// 부드러운 그라데이션 바탕: 어두운 모드는 검정에 아래쪽 주황빛, 밝은 모드는 연한 복숭아빛
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.hi.opacity(0.18), .clear], center: .init(x: 0.5, y: 1.08), startRadius: 0, endRadius: 520)
        }
    }
}

/// 테마 색 설정 (이 기기에만 저장). 값은 프리셋 이름 또는 "#RRGGBB".
enum ThemePrefs {
    static let accentKey = "themeAccent"
    static let lateKey = "themeLate"
    struct Preset: Identifiable { let id: String; let name: String; let light: UInt32; let dark: UInt32 }
    static let accents: [Preset] = [
        .init(id: "orange", name: "오렌지", light: 0xE86F00, dark: 0xFFA526),
        .init(id: "blue", name: "블루", light: 0x0A6FE0, dark: 0x4DA3FF),
        .init(id: "teal", name: "민트", light: 0x0E9F8E, dark: 0x3DD6C3),
        .init(id: "green", name: "그린", light: 0x2E9E4F, dark: 0x4ADE80),
        .init(id: "purple", name: "퍼플", light: 0x7C4DDB, dark: 0xB18CFF),
        .init(id: "pink", name: "핑크", light: 0xD6336C, dark: 0xFF7AA8),
        .init(id: "gray", name: "그래파이트", light: 0x5F6368, dark: 0xC9CDD3),
    ]
    static let lates: [Preset] = [
        .init(id: "coral", name: "코랄", light: 0xD4756B, dark: 0xE8928A),
        .init(id: "rose", name: "로즈", light: 0xC9788F, dark: 0xE59BB0),
        .init(id: "amber", name: "앰버", light: 0xC98A1B, dark: 0xE8B04A),
        .init(id: "lav", name: "라벤더", light: 0x8A78D0, dark: 0xB3A4F0),
        .init(id: "slate", name: "슬레이트", light: 0x7C8796, dark: 0xA3ADBB),
        .init(id: "red", name: "레드", light: 0xE0352B, dark: 0xFF453A),
    ]
    private static func value(_ key: String, _ def: String) -> String { Store.defaults.string(forKey: key) ?? def }
    static func hex(_ s: String) -> UInt32? {
        guard s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return v
    }
    static func color(_ list: [Preset], key: String) -> Color {
        if let h = hex(key) { return Color(Theme.rgb(h)) }
        let p = list.first { $0.id == key } ?? list[0]
        return Theme.adaptive(Theme.rgb(p.light), Theme.rgb(p.dark))
    }
    static var accent: Color { color(accents, key: value(accentKey, "orange")) }
    static var late: Color { color(lates, key: value(lateKey, "coral")) }
    static var accentSoft: Color {
        let k = value(accentKey, "orange")
        if let h = hex(k) { return Color(Theme.rgb(h, 0.16)) }
        let p = accents.first { $0.id == k } ?? accents[0]
        return Theme.adaptive(Theme.rgb(p.light, 0.14), Theme.rgb(p.dark, 0.18))
    }
    static func uiHex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }
}
