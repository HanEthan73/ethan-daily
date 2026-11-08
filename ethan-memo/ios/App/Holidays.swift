import Foundation
import Observation

/// 공휴일: 공공데이터포털 특일 정보를 매일 갱신하는 holidays.hyunbin.page + 내장 표(2025~2027)
@MainActor
@Observable
final class Holidays {
    static let shared = Holidays()
    private(set) var map: [String: String] = Holidays.base
    private var years: Set<String> = ["2025", "2026", "2027"]
    private let url = URL(string: "https://holidays.hyunbin.page/basic.json")!

    static let base: [String: String] = [
        "2025-01-01": "신정", "2025-01-27": "임시공휴일", "2025-01-28": "설날 전날", "2025-01-29": "설날", "2025-01-30": "설날 다음 날",
        "2025-03-01": "삼일절", "2025-03-03": "대체공휴일", "2025-05-05": "어린이날 · 부처님 오신 날", "2025-05-06": "대체공휴일",
        "2025-06-03": "대통령선거", "2025-06-06": "현충일", "2025-08-15": "광복절", "2025-10-03": "개천절", "2025-10-05": "추석 전날",
        "2025-10-06": "추석", "2025-10-07": "추석 다음 날", "2025-10-08": "대체공휴일", "2025-10-09": "한글날", "2025-12-25": "크리스마스",
        "2026-01-01": "신정", "2026-02-16": "설날 전날", "2026-02-17": "설날", "2026-02-18": "설날 다음 날", "2026-03-01": "삼일절",
        "2026-03-02": "대체공휴일", "2026-05-01": "노동절", "2026-05-05": "어린이날", "2026-05-24": "부처님 오신 날", "2026-05-25": "대체공휴일",
        "2026-06-03": "지방선거", "2026-06-06": "현충일", "2026-07-17": "제헌절", "2026-08-15": "광복절", "2026-08-17": "대체공휴일",
        "2026-09-24": "추석 전날", "2026-09-25": "추석", "2026-09-26": "추석 다음 날", "2026-10-03": "개천절", "2026-10-05": "대체공휴일",
        "2026-10-09": "한글날", "2026-12-25": "크리스마스",
        "2027-01-01": "신정", "2027-02-06": "설날 전날", "2027-02-07": "설날", "2027-02-08": "설날 다음 날", "2027-02-09": "대체공휴일",
        "2027-03-01": "삼일절", "2027-05-01": "노동절", "2027-05-03": "대체공휴일", "2027-05-05": "어린이날", "2027-05-13": "부처님 오신 날",
        "2027-06-06": "현충일", "2027-07-17": "제헌절", "2027-07-19": "대체공휴일", "2027-08-15": "광복절", "2027-08-16": "대체공휴일",
        "2027-09-14": "추석 전날", "2027-09-15": "추석", "2027-09-16": "추석 다음 날", "2027-10-03": "개천절", "2027-10-04": "대체공휴일",
        "2027-10-09": "한글날", "2027-10-11": "대체공휴일", "2027-12-25": "크리스마스", "2027-12-27": "대체공휴일",
    ]
    static let fixed: [String: String] = ["01-01": "신정", "03-01": "삼일절", "05-01": "노동절", "05-05": "어린이날", "06-06": "현충일",
                                          "07-17": "제헌절", "08-15": "광복절", "10-03": "개천절", "10-09": "한글날", "12-25": "크리스마스"]

    init() {
        if let d = Store.defaults.data(forKey: "holidays.data"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: [String]]] { apply(j) }
    }

    func name(_ date: Date) -> String? {
        let k = Fmt.string(date, "yyyy-MM-dd")
        if let n = map[k] { return n }
        let y = String(k.prefix(4))
        if years.contains(y) || (Int(y) ?? 0) < 2025 { return nil }
        return Self.fixed[String(k.suffix(5))]
    }

    func short(_ date: Date) -> String? {
        guard let n = name(date) else { return nil }
        if n.contains("대체") { return "대체휴일" }
        return n.components(separatedBy: " · ").first
    }

    func refresh() async {
        let last = Store.defaults.double(forKey: "holidays.at")
        if Date().timeIntervalSince1970 - last < 86400, Store.defaults.data(forKey: "holidays.data") != nil { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [String]]] else { return }
        apply(j)
        Store.defaults.set(data, forKey: "holidays.data")
        Store.defaults.set(Date().timeIntervalSince1970, forKey: "holidays.at")
    }

    private func apply(_ j: [String: [String: [String]]]) {
        var out = Self.base
        var ys = years
        for (y, days) in j {
            ys.insert(y)
            for k in out.keys where k.hasPrefix(y + "-") { out[k] = nil }
            for (d, names) in days { out[d] = names.map(Self.clean).joined(separator: " · ") }
        }
        map = out
        years = ys
    }

    static func clean(_ n: String) -> String {
        var s = n.replacingOccurrences(of: "기독탄신일", with: "크리스마스")
            .replacingOccurrences(of: "1월 1일", with: "신정")
            .replacingOccurrences(of: "3ㆍ1절", with: "삼일절")
            .replacingOccurrences(of: "전국동시지방선거", with: "지방선거")
        if s.hasPrefix("대체공휴일(") { s = "대체공휴일" }
        return s
    }
}
