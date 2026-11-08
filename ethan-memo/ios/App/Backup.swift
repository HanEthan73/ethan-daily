import Foundation
import SwiftData

/// 웹앱과 같은 JSON 형식: 웹 ↔ iOS 사이에서도 옮길 수 있음
struct BackupFile: Codable {
    var app: String = "ETHAN MEMO"
    var version: Int = 1
    var exportedAt: Double
    var items: [BackupItem]
    var pages: [BackupPage]? = nil
}

struct BackupPage: Codable {
    var id: String
    var title: String
    var body: String
    var createdAt: Double?
    var updatedAt: Double?
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
    var note: String? = nil
    var photos: [String]? = nil
    var updatedAt: Double? = nil
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
                       answer: i.answer, answeredAt: ms(i.answeredAt),
                       note: i.note.isEmpty ? nil : i.note, photos: i.photoIDs, updatedAt: ms(i.updatedAt))
        }
        let wiki = try ctx.fetch(FetchDescriptor<WikiPage>()).map {
            BackupPage(id: $0.uid, title: $0.title, body: $0.body, createdAt: ms($0.createdAt), updatedAt: ms($0.updatedAt))
        }
        let file = BackupFile(exportedAt: Date().timeIntervalSince1970 * 1000, items: items, pages: wiki)
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
        return try merge(file, into: ctx, keep: false)
    }

    /// 가져오기 링크(#import=…) 또는 코드 → 기록 추가 (이미 있는 것은 건드리지 않음)
    @discardableResult
    static func importCode(_ raw: String, into ctx: ModelContext) throws -> Int {
        var code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = code.range(of: "import=") { code = String(code[r.upperBound...]) }
        code = String(code.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        var b64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard code.count > 20, let z = Data(base64Encoded: b64),
              let raw = try? (z as NSData).decompressed(using: .zlib) as Data,
              let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var items: [BackupItem] = []
        if let t = j["t"] as? [[Any]], let d = j["d"] as? String {
            for row in t where row.count >= 2 {
                guard let id = row[0] as? String, let text = row[1] as? String else { continue }
                let at = (row.count > 2 ? row[2] as? NSNumber : nil)?.doubleValue
                items.append(BackupItem(id: "rem-" + id, type: "todo", date: d, text: text, done: false, createdAt: at))
            }
        } else {
            let file = try JSONDecoder().decode(BackupFile.self, from: raw)
            items = file.items
        }
        let r = try merge(BackupFile(exportedAt: Date().timeIntervalSince1970 * 1000, items: items), into: ctx, keep: true)
        return r.added
    }

    static func merge(_ file: BackupFile, into ctx: ModelContext, keep: Bool) throws -> (added: Int, updated: Int) {
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
                if keep { continue }
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
            item.note = b.note ?? ""
            item.photoIDs = b.photos ?? []
        }
        let existingPages = try ctx.fetch(FetchDescriptor<WikiPage>())
        var pageById: [String: WikiPage] = [:]
        for p in existingPages { pageById[p.uid] = p }
        for b in file.pages ?? [] where !b.title.isEmpty {
            let p: WikiPage
            if let old = pageById[b.id] { p = old; updated += 1 } else { p = WikiPage(title: b.title); p.uid = b.id; ctx.insert(p); pageById[b.id] = p; added += 1 }
            p.title = b.title
            p.body = b.body
            p.createdAt = date(b.createdAt) ?? p.createdAt
            p.updatedAt = date(b.updatedAt) ?? .now
        }
        Store.save(ctx)
        return (added, updated)
    }
}
