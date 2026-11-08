import Foundation
import SwiftData

enum Kind: String, Codable, CaseIterable, Identifiable {
    case memo, todo, event
    var id: String { rawValue }
    var label: String {
        switch self {
        case .memo: return "메모"
        case .todo: return "할 일"
        case .event: return "일정"
        }
    }
}

@Model
final class Item {
    @Attribute(.unique) var uid: String
    var kindRaw: String
    /// 시작일(자정 기준)
    var day: Date
    /// 여러 날 일정의 마지막 날(자정 기준). 하루짜리면 nil
    var endDay: Date?
    /// 시각(시·분만 사용). nil이면 종일/시간 없음
    var time: Date?
    var text: String
    var done: Bool
    var doneAt: Date?
    var createdAt: Date
    var answer: String?
    var answeredAt: Date?
    /// 상세 내용(마크다운)
    var note: String = ""
    /// 사진 파일 ID 목록 (PhotoStore)
    var photoIDs: [String] = []
    /// 마지막 수정 시각 (동기화 병합 기준)
    var updatedAt: Date? = nil
    /// 꾹 눌러 맨 위 고정
    var pinned: Bool = false
    var pinnedAt: Date? = nil

    init(kind: Kind, day: Date, endDay: Date? = nil, time: Date? = nil, text: String) {
        let start = Fmt.cal.startOfDay(for: day)
        var last: Date? = nil
        if let endDay {
            let e = Fmt.cal.startOfDay(for: endDay)
            if e > start { last = e }
        }
        self.uid = UUID().uuidString
        self.kindRaw = kind.rawValue
        self.day = start
        self.endDay = last
        self.time = time
        self.text = text
        self.done = false
        self.doneAt = nil
        self.createdAt = .now
        self.updatedAt = .now
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .memo }
        set { kindRaw = newValue.rawValue }
    }

    /// 마지막 날 (하루짜리면 시작일)
    var lastDay: Date { endDay ?? day }
    var isMultiDay: Bool { endDay != nil }

    func covers(_ d: Date) -> Bool {
        let x = Fmt.cal.startOfDay(for: d)
        return x >= day && x <= lastDay
    }
}
