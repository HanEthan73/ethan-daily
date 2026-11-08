import Foundation
import Observation

/// 탭 이동과 위키·캘린더 사이 점프
@MainActor
@Observable
final class Router {
    static let shared = Router()
    var tab: Tab = .todo
    var jumpDate: Date?
    var wikiTitle: String?
    var wikiDay: Date?

    func go(date: Date) {
        jumpDate = Fmt.cal.startOfDay(for: date)
        tab = .calendar
    }

    /// [[제목]] 탭: 날짜면 캘린더로, 아니면 위키 페이지로 (없으면 새로 만듦)
    func open(link: String) {
        if let d = WikiText.date(link) { wikiDay = d; tab = .wiki; return }
        wikiTitle = link
        tab = .wiki
    }
}
