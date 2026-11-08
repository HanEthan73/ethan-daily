import Foundation
import SwiftData

/// 위키 페이지: [[제목]]으로 서로 연결되는 마크다운 노트
@Model
final class WikiPage {
    @Attribute(.unique) var uid: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(title: String, body: String = "") {
        self.uid = "w" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        self.title = title
        self.body = body
        self.createdAt = .now
        self.updatedAt = .now
    }
}

enum WikiText {
    /// 본문 속 [[링크]] 대상 목록 (별칭 | 뒤는 제외)
    static func links(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            let t = raw.split(separator: "|", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// [[제목|별칭]] → 별칭(없으면 제목)
    static func plain(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) else { return text }
        let ns = text as NSString
        var s = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 1))
            s = (s as NSString).replacingCharacters(in: m.range, with: label.trimmingCharacters(in: .whitespaces))
        }
        return s
    }

    static func isDate(_ t: String) -> Bool {
        t.trimmingCharacters(in: .whitespaces).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    static func date(_ t: String) -> Date? {
        guard isDate(t) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Fmt.cal
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: t.trimmingCharacters(in: .whitespaces))
    }

    /// 다른 페이지·기록 속 [[old]] → [[new]]
    static func rename(_ text: String, from old: String, to new: String) -> String {
        let pattern = #"\[\["# + NSRegularExpression.escapedPattern(for: old) + #"(\|[^\]]*)?\]\]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let tmpl = "[[" + NSRegularExpression.escapedTemplate(for: new) + "$1]]"
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: tmpl)
    }

    static func snippet(_ body: String) -> String {
        for line in body.split(separator: "\n") {
            var s = String(line)
            s = s.replacingOccurrences(of: #"^\s*(#+|>|[-*+]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
            s = plain(s).replacingOccurrences(of: #"[*`~|]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !s.isEmpty && s.range(of: #"^-+$"#, options: .regularExpression) == nil { return String(s.prefix(90)) }
        }
        return ""
    }
}
