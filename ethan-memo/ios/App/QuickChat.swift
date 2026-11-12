import Foundation

// MARK: - 무료 모드(API 키 없이): 한국어 문장을 앱 안에서 바로 해석 (웹 index.html의 quickParse와 같은 규칙)

enum QuickChat {
    struct Parsed {
        var type: String      // event | todo | memo
        var text: String
        var date: String      // yyyy-MM-dd
        var time: String      // HH:mm 또는 ""
    }

    private static func match(_ pat: String, _ s: String) -> (full: String, g: [String])? {
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        var g: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return (g[0], Array(g.dropFirst()))
    }
    private static func test(_ pat: String, _ s: String) -> Bool { s.range(of: pat, options: .regularExpression) != nil }
    private static func cut(_ s: inout String, _ piece: String) {
        if let r = s.range(of: piece) { s.replaceSubrange(r, with: " ") }
    }
    private static func sub(_ s: String, _ pat: String) -> String {
        s.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
    }
    private static func p2(_ n: Int) -> String { String(format: "%02d", n) }
    private static func ymd(_ d: Date) -> String {
        let c = Fmt.cal.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(p2(c.month ?? 1))-\(p2(c.day ?? 1))"
    }
    private static let wd = Array("일월화수목금토")
    private static func weekday(_ ch: String) -> Int { wd.firstIndex(of: Character(ch)) ?? 0 }

    static let todoKW = "(제출|사야|사기|사오|구매|보내|챙기|확인|정리|마무리|신청|결제|연락|전화|해야|끝내|준비|작성|검토|수정|청소|빨래|운동|납부|가져|챙겨)"
    static let evtKW = "(미팅|약속|회식|만나|출장|면접|병원|치과|수업|회의|세미나|공연|여행|예약|식사|모임|파티|결혼|콘서트|시험|방문|진료|상담)"

    static func parse(_ text: String, today: Date = .now) -> [Parsed] {
        let t0 = Fmt.cal.startOfDay(for: today)
        let t0s = ymd(t0)
        let dow = Fmt.cal.component(.weekday, from: t0) - 1
        let cal = Fmt.cal
        var out: [Parsed] = []
        let normalized = text.replacingOccurrences(of: #"\s그리고\s|\s및\s"#, with: ",", options: .regularExpression)
        for raw in normalized.components(separatedBy: CharacterSet(charactersIn: ",，.。\n")) {
            let c = raw.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            var s = c
            var date: String?
            var time = ""
            let until = c.contains("까지")

            func addDays(_ n: Int) -> String { ymd(Fmt.addDays(t0, n)) }
            func fixedDate(_ mo: Int, _ dd: Int) -> String {
                let y = cal.component(.year, from: t0)
                var k = "\(y)-\(p2(mo))-\(p2(dd))"
                if k < t0s { k = "\(y + 1)-\(p2(mo))-\(p2(dd))" }
                return k
            }

            if let m = match(#"(\d{1,2})\s*월\s*(\d{1,2})\s*일"#, s) ?? match(#"(?<!\d)(\d{1,2})/(\d{1,2})(?!\d)"#, s) {
                date = fixedDate(Int(m.g[0]) ?? 1, Int(m.g[1]) ?? 1); cut(&s, m.full)
            } else if let m = match(#"(\d{1,3})\s*일\s*(?:후|뒤)"#, s) {
                date = addDays(Int(m.g[0]) ?? 0); cut(&s, m.full)
            } else if let m = match(#"(\d)\s*주\s*(?:후|뒤)"#, s) {
                date = addDays(7 * (Int(m.g[0]) ?? 0)); cut(&s, m.full)
            } else if let m = match(#"(다다음|다음|이번|담)\s*주\s*([월화수목금토일])(?:요일)?"#, s) {
                let add = m.g[0] == "이번" ? 0 : (m.g[0] == "다다음" ? 14 : 7)
                date = addDays(weekday(m.g[1]) - dow + add); cut(&s, m.full)
            } else if let m = match(#"(오늘|내일|모레|글피|어제)"#, s) {
                let n = ["오늘": 0, "내일": 1, "모레": 2, "글피": 3, "어제": -1][m.g[0]] ?? 0
                date = addDays(n); cut(&s, m.full)
            } else if let m = match(#"([월화수목금토일])요일"#, s) {
                date = addDays((weekday(m.g[0]) - dow + 7) % 7); cut(&s, m.full)
            } else if let m = match(#"(?<![\d월])(\d{1,2})\s*일(?!\s*(?:후|뒤|간))"#, s) {
                let y = cal.component(.year, from: t0), mo = cal.component(.month, from: t0)
                let dd = Int(m.g[0]) ?? 1
                var k = "\(y)-\(p2(mo))-\(p2(dd))"
                if k < t0s {
                    let n = cal.date(byAdding: .month, value: 1, to: t0) ?? t0
                    k = "\(cal.component(.year, from: n))-\(p2(cal.component(.month, from: n)))-\(p2(dd))"
                }
                date = k; cut(&s, m.full)
            }

            if let m = match(#"(오전|오후|아침|저녁|밤|새벽|점심)?\s*(\d{1,2})\s*시\s*(?:(\d{1,2})\s*분|(반))?"#, s) {
                var h = Int(m.g[1]) ?? 0
                let mi = !m.g[2].isEmpty ? (Int(m.g[2]) ?? 0) : (!m.g[3].isEmpty ? 30 : 0)
                let ap = m.g[0]
                if test("오후|저녁|밤", ap) { if h < 12 { h += 12 } }
                else if test("오전|아침|새벽", ap) { if h == 12 { h = 0 } }
                else if ap.contains("점심") { if h < 11 { h += 12 } }
                else if h >= 1 && h <= 6 { h += 12 }
                if h < 24 && mi < 60 { time = "\(p2(h)):\(p2(mi))"; cut(&s, m.full) }
            } else if let m = match(#"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)"#, s) {
                time = "\(p2(Int(m.g[0]) ?? 0)):\(m.g[1])"; cut(&s, m.full)
            }

            let isMemo = test(#"^\s*(메모|기록)"#, c) || test(#"메모\s*(해|로)"#, c)
            s = sub(s, #"(메모|기록)\s*(해\s*줘|해줘|해|로|:)?"#)
            s = sub(s, #"(일정|약속|할\s*일)?\s*(등록|추가|잡아|넣어|저장)\s*(해\s*줘|해줘|해|줘|주세요)?"#)
            s = sub(s, #"(해\s*줘|해줘|줘|주세요)\s*$"#)
            s = sub(s, #"(오늘|내일|모레)"#)
            s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            s = s.replacingOccurrences(of: #"^(에|에는|까지|부터|은|는|도|이|가)\s+"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\s+(에|까지|부터)$"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(에|까지)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let body = s.isEmpty ? c : s

            let type: String
            if isMemo { type = "memo" }
            else if until { type = "todo" }
            else if !time.isEmpty { type = (test(todoKW, body) && !test(evtKW, body)) ? "todo" : "event" }
            else if test(evtKW, body) && date != nil { type = "event" }
            else { type = "todo" }
            out.append(Parsed(type: type, text: body, date: date ?? t0s, time: time))
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// 질문 문장이 "일정·할 일 알려줘"류인지 보고 목록 범위를 돌려줌
    static func listRange(_ text: String, today: Date = .now) -> (label: String, from: Date, to: Date)? {
        guard test("(일정|할\\s*일|할일|메모)", text), test("(알려|보여|뭐|있어|있나|확인)", text) else { return nil }
        let t0 = Fmt.cal.startOfDay(for: today)
        let dow = Fmt.cal.component(.weekday, from: t0) - 1
        if text.contains("내일") { let d = Fmt.addDays(t0, 1); return ("내일", d, d) }
        if text.contains("모레") { let d = Fmt.addDays(t0, 2); return ("모레", d, d) }
        if test("이번\\s*주|금주", text) { return ("이번 주", Fmt.addDays(t0, -dow), Fmt.addDays(t0, 6 - dow)) }
        if test("다음\\s*주", text) { return ("다음 주", Fmt.addDays(t0, 7 - dow), Fmt.addDays(t0, 13 - dow)) }
        return ("오늘", t0, t0)
    }

    static func isQuestion(_ text: String) -> Bool {
        test(#"[?？]\s*$|왜|어떻게|추천|설명|뭐야|뭔가요|알려\s*줘|알려줘|비교|차이"#, text) && !test("(등록|추가)", text)
    }
    static func isEditCommand(_ text: String) -> Bool {
        test(#"(삭제|지워|지우|취소|완료\s*(처리|해)|수정|바꿔|변경)"#, text) && !test("(등록|추가)", text)
    }
}
