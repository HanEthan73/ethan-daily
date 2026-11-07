import Foundation
import SwiftData

/// 웹앱과 같은 JSON 형식: 웹 ↔ iOS 사이에서도 옮길 수 있음
struct BackupFile: Codable {
    var app: String = "ETHAN MEMO"
    var version: Int = 1
    var exportedAt: Double
    var items: [BackupItem]
}

struct BackupItem: Codable {
    var id: String
    var type: String
    var date: String
    var endDate: String?
    var time: String?
    var text: String
    var done: Bool?
    var doneAt: Double?
    var createdAt: Double?
    var answer: String?
    var answeredAt: Double?
}

enum Backup {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Fmt.cal
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static func ms(_ d: Date?) -> Double? { d.map { $0.timeIntervalSince1970 * 1000 } }
    private static func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// 전체 기록을 JSON 파일로 만들어 임시 폴더에 저장하고 그 주소를 돌려줌
    static func export(_ ctx: ModelContext) throws -> URL {
        let all = try ctx.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\Item.createdAt)]))
        let items = all.map { i in
            BackupItem(id: i.uid, type: i.kindRaw, date: dayFmt.string(from: i.day),
                       endDate: i.endDay.map { dayFmt.string(from: $0) },
                       time: i.time.map { timeFmt.string(from: $0) },
                       text: i.text, done: i.done, doneAt: ms(i.doneAt), createdAt: ms(i.createdAt),
                       answer: i.answer, answeredAt: ms(i.answeredAt))
        }
        let file = BackupFile(exportedAt: Date().timeIntervalSince1970 * 1000, items: items)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(file)
        let name = "ETHAN-MEMO-백업-\(Fmt.string(.now, "yyMMdd-HHmm")).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 백업 파일을 합쳐 넣음: 같은 ID는 덮어쓰고, 없는 것은 추가 (기존 기록은 지우지 않음)
    @discardableResult
    static func restore(from url: URL, into ctx: ModelContext) throws -> (added: Int, updated: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(BackupFile.self, from: data)
        let existing = try ctx.fetch(FetchDescriptor<Item>())
        var byId: [String: Item] = [:]
        for i in existing { byId[i.uid] = i }
        var added = 0, updated = 0
        for b in file.items {
            guard let day = dayFmt.date(from: b.date), !b.text.isEmpty else { continue }
            let kind = Kind(rawValue: b.type) ?? .memo
            let end = b.endDate.flatMap { $0.isEmpty ? nil : dayFmt.date(from: $0) }
            let time = b.time.flatMap { t -> Date? in
                guard !t.isEmpty, let hm = timeFmt.date(from: t) else { return nil }
                let c = Fmt.cal.dateComponents([.hour, .minute], from: hm)
                return Fmt.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day)
            }
            let item: Item
            if let old = byId[b.id] {
                item = old
                updated += 1
            } else {
                item = Item(kind: kind, day: day, text: b.text)
                item.uid = b.id
                ctx.insert(item)
                byId[b.id] = item
                added += 1
            }
            item.kind = kind
            item.day = Fmt.cal.startOfDay(for: day)
            item.endDay = (end != nil && end! > item.day) ? Fmt.cal.startOfDay(for: end!) : nil
            item.time = kind == .memo ? nil : time
            item.text = b.text
            item.done = b.done ?? false
            item.doneAt = date(b.doneAt)
            item.createdAt = date(b.createdAt) ?? item.createdAt
            item.answer = b.answer
            item.answeredAt = date(b.answeredAt)
        }
        Store.save(ctx)
        return (added, updated)
    }
}
