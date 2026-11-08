import Foundation
import SwiftData
import Observation

/// PC·웹과 같은 데이터: GitHub 비공개 저장소의 ethan-memo.json (웹 앱과 같은 형식)
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()
    enum State { case off, busy, ok, err }
    var state: State = .off
    var error = ""
    var last: Date? = Store.defaults.object(forKey: "gh.last") as? Date

    private var timer: Task<Void, Never>?
    private var running = false
    private var again = false
    private let file = "ethan-memo.json"

    var repo: String {
        get { Store.defaults.string(forKey: "gh.repo") ?? "" }
        set { Store.defaults.set(Self.cleanRepo(newValue), forKey: "gh.repo") }
    }
    var token: String? { Keychain.read(account: "ghToken") }
    var on: Bool { !repo.isEmpty && token != nil }

    static func cleanRepo(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespacesAndNewlines)
        r = r.replacingOccurrences(of: "https://github.com/", with: "")
        if r.hasSuffix(".git") { r.removeLast(4) }
        if r.hasSuffix("/") { r.removeLast() }
        return r
    }

    func schedule(_ delay: Double = 1.5) {
        guard on else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.run()
        }
    }

    // MARK: GitHub API

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let token, let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else { throw SyncError.message("저장소 설정을 확인하세요") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    enum SyncError: Error { case status(Int), message(String) }

    private func pull() async throws -> (doc: [String: Any], sha: String?) {
        let (d, code) = try await request("contents/\(file)")
        if code == 404 {
            let (_, rc) = try await request("")
            if rc == 404 { throw SyncError.status(404) }
            return ([:], nil)
        }
        guard code == 200, let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let sha = j["sha"] as? String else { throw SyncError.status(code) }
        var b64 = (j["content"] as? String) ?? ""
        if b64.isEmpty {
            let (bd, bc) = try await request("git/blobs/\(sha)")
            guard bc == 200, let bj = try JSONSerialization.jsonObject(with: bd) as? [String: Any] else { throw SyncError.status(bc) }
            b64 = (bj["content"] as? String) ?? ""
        }
        guard let raw = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")),
              let doc = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw SyncError.message("저장소의 데이터 파일을 읽지 못했습니다") }
        return (doc, sha)
    }

    // MARK: 동기화

    func run() async {
        guard on else { state = .off; return }
        if running { again = true; return }
        running = true
        state = .busy
        do {
            for attempt in 0..<3 {
                let (remote, sha) = try await pull()
                let ctx = Store.container.mainContext
                let merged = try merge(remote, ctx: ctx)
                let localCanon = Self.canon(merged)
                let remoteCanon = Self.canon(remote)
                if sha != nil && localCanon == remoteCanon { break }
                let data = try JSONSerialization.data(withJSONObject: merged)
                var body: [String: Any] = ["message": "ETHAN MEMO 동기화 (iPhone)", "content": data.base64EncodedString()]
                if let sha { body["sha"] = sha }
                let (_, code) = try await request("contents/\(file)", method: "PUT", body: body)
                if code == 200 || code == 201 { break }
                if (code == 409 || code == 422) && attempt < 2 { continue }
                throw SyncError.status(code)
            }
            await uploadPhotos()
            last = .now
            Store.defaults.set(last, forKey: "gh.last")
            state = .ok
            error = ""
        } catch SyncError.status(let c) {
            state = .err
            error = c == 401 ? "토큰이 올바르지 않거나 만료되었습니다" : c == 404 ? "저장소를 찾을 수 없습니다. 이름과 토큰 권한을 확인하세요"
                : c == 403 ? "토큰에 이 저장소 쓰기 권한(Contents)이 없습니다" : "동기화하지 못했습니다 (\(c))"
        } catch SyncError.message(let m) {
            state = .err
            error = m
        } catch {
            state = .err
            self.error = "네트워크 문제로 동기화하지 못했습니다"
        }
        running = false
        if again { again = false; schedule(0.3) }
    }

    /// 원격과 이 기기를 합쳐 이 기기에 반영하고, 합친 문서를 돌려줌
    private func merge(_ remote: [String: Any], ctx: ModelContext) throws -> [String: Any] {
        var dead = Dead.load()
        for (k, v) in (remote["dead"] as? [String: Any]) ?? [:] { if let n = Self.num(v) { dead[k] = max(dead[k] ?? 0, n) } }
        let cut = Date().timeIntervalSince1970 * 1000 - 120 * 86_400_000
        dead = dead.filter { $0.value >= cut }

        // 할 일·메모·일정
        let items = try ctx.fetch(FetchDescriptor<Item>())
        var localItems: [String: Item] = [:]
        for i in items { localItems[i.uid] = i }
        var remoteItems: [String: [String: Any]] = [:]
        for r in (remote["items"] as? [[String: Any]]) ?? [] { if let id = r["id"] as? String { remoteItems[id] = r } }
        for id in Set(localItems.keys).union(remoteItems.keys) {
            let l = localItems[id], r = remoteItems[id]
            let ls = l.map(Self.stamp) ?? -1, rs = r.map(Self.stamp) ?? -1
            if let dv = dead[id], dv >= max(ls, rs) {
                if let l { ctx.delete(l) }
                continue
            }
            if let r, rs > ls {
                let target = l ?? { let n = Item(kind: .memo, day: .now, text: ""); n.uid = id; ctx.insert(n); return n }()
                Self.apply(r, to: target)
            }
        }
        // 위키 페이지
        let pages = try ctx.fetch(FetchDescriptor<WikiPage>())
        var localPages: [String: WikiPage] = [:]
        for p in pages { localPages[p.uid] = p }
        var remotePages: [String: [String: Any]] = [:]
        for r in (remote["pages"] as? [[String: Any]]) ?? [] { if let id = r["id"] as? String { remotePages[id] = r } }
        for id in Set(localPages.keys).union(remotePages.keys) {
            let l = localPages[id], r = remotePages[id]
            let ls = l.map { $0.updatedAt.timeIntervalSince1970 * 1000 } ?? -1
            let rs = r.flatMap { Self.num($0["updatedAt"]) ?? Self.num($0["createdAt"]) } ?? -1
            if let dv = dead[id], dv >= max(ls, rs) {
                if let l { ctx.delete(l) }
                continue
            }
            if let r, rs > ls {
                let target = l ?? { let n = WikiPage(title: ""); n.uid = id; ctx.insert(n); return n }()
                target.title = (r["title"] as? String) ?? target.title
                target.body = (r["body"] as? String) ?? ""
                if let c = Self.num(r["createdAt"]) { target.createdAt = Date(timeIntervalSince1970: c / 1000) }
                target.updatedAt = Date(timeIntervalSince1970: rs / 1000)
            }
        }
        try ctx.save()   // 원격 내용 반영은 수정 시각을 새로 찍지 않음
        Dead.save(dead)
        Store.refreshWidgets()

        let outItems = try ctx.fetch(FetchDescriptor<Item>()).map(Self.dict).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        let outPages = try ctx.fetch(FetchDescriptor<WikiPage>()).map { p -> [String: Any] in
            ["id": p.uid, "title": p.title, "body": p.body, "createdAt": Self.ms(p.createdAt), "updatedAt": Self.ms(p.updatedAt)]
        }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        return ["app": "ETHAN MEMO", "version": 2, "items": outItems, "pages": outPages, "dead": dead.mapValues { Int64($0) }]
    }

    // MARK: 사진

    private func uploadPhotos() async {
        var up = Set(Store.defaults.stringArray(forKey: "photos.up") ?? [])
        let ctx = Store.container.mainContext
        let ids = ((try? ctx.fetch(FetchDescriptor<Item>())) ?? []).flatMap(\.photoIDs)
        for id in ids where !up.contains(id) && PhotoStore.exists(id) {
            guard let d = try? Data(contentsOf: PhotoStore.url(id)) else { continue }
            let r = try? await request("contents/photos/\(id).jpg", method: "PUT", body: ["message": "사진 \(id)", "content": d.base64EncodedString()])
            if let c = r?.1, c == 200 || c == 201 || c == 422 { up.insert(id) }
        }
        Store.defaults.set(Array(up), forKey: "photos.up")
    }

    func download(photo id: String) async -> Bool {
        guard on else { return false }
        guard let res = try? await request("contents/photos/\(id).jpg"), res.1 == 200,
              let j = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any] else { return false }
        var b64 = (j["content"] as? String) ?? ""
        if b64.isEmpty, let sha = j["sha"] as? String,
           let br = try? await request("git/blobs/\(sha)"), br.1 == 200,
           let bj = try? JSONSerialization.jsonObject(with: br.0) as? [String: Any] { b64 = (bj["content"] as? String) ?? "" }
        guard let raw = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else { return false }
        PhotoStore.write(id, data: raw)
        var up = Set(Store.defaults.stringArray(forKey: "photos.up") ?? [])
        up.insert(id)
        Store.defaults.set(Array(up), forKey: "photos.up")
        return true
    }

    // MARK: 변환 (웹 앱과 같은 필드)

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Fmt.cal; f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is Bool) { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func stamp(_ i: Item) -> Double {
        (i.updatedAt ?? i.doneAt ?? i.createdAt).timeIntervalSince1970 * 1000
    }
    static func stamp(_ r: [String: Any]) -> Double {
        num(r["updatedAt"]) ?? num(r["doneAt"]) ?? num(r["createdAt"]) ?? 0
    }

    static func dict(_ i: Item) -> [String: Any] {
        let null = NSNull()
        return [
            "id": i.uid, "type": i.kindRaw, "date": dayFmt.string(from: i.day),
            "endDate": i.endDay.map { dayFmt.string(from: $0) } ?? null,
            "time": i.time.map { timeFmt.string(from: $0) } ?? null,
            "text": i.text, "note": i.note.isEmpty ? null : i.note, "photos": i.photoIDs,
            "done": i.done, "doneAt": i.doneAt.map(ms) ?? null, "createdAt": ms(i.createdAt),
            "updatedAt": i.updatedAt.map(ms) ?? null, "answer": i.answer ?? null, "answeredAt": i.answeredAt.map(ms) ?? null,
        ]
    }

    static func apply(_ r: [String: Any], to i: Item) {
        let day = (r["date"] as? String).flatMap { dayFmt.date(from: $0) } ?? i.day
        i.kindRaw = ["memo", "todo", "event"].contains(r["type"] as? String ?? "") ? (r["type"] as! String) : "memo"
        i.day = Fmt.cal.startOfDay(for: day)
        if let e = (r["endDate"] as? String).flatMap({ $0.isEmpty ? nil : dayFmt.date(from: $0) }), e > i.day { i.endDay = Fmt.cal.startOfDay(for: e) } else { i.endDay = nil }
        if let t = r["time"] as? String, !t.isEmpty, let hm = timeFmt.date(from: t) {
            let c = Fmt.cal.dateComponents([.hour, .minute], from: hm)
            i.time = Fmt.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: i.day)
        } else { i.time = nil }
        i.text = (r["text"] as? String) ?? ""
        i.note = (r["note"] as? String) ?? ""
        i.photoIDs = (r["photos"] as? [String]) ?? []
        i.done = (r["done"] as? Bool) ?? false
        i.doneAt = num(r["doneAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        if let c = num(r["createdAt"]) { i.createdAt = Date(timeIntervalSince1970: c / 1000) }
        i.updatedAt = Date(timeIntervalSince1970: stamp(r) / 1000)
        i.answer = r["answer"] as? String
        i.answeredAt = num(r["answeredAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// 비교용 표준 형태 (필드·빈 값·숫자 표기를 맞춤)
    static func canon(_ doc: [String: Any]) -> String {
        func n(_ v: Any?) -> Any { num(v).map { Int64($0.rounded()) as Any } ?? NSNull() }
        func str(_ v: Any?) -> Any { if let s = v as? String, !s.isEmpty { return s }; return NSNull() }
        let items = ((doc["items"] as? [[String: Any]]) ?? []).map { r -> [String: Any] in
            ["id": r["id"] as? String ?? "", "type": r["type"] as? String ?? "", "date": r["date"] as? String ?? "",
             "endDate": str(r["endDate"]), "time": str(r["time"]), "text": r["text"] as? String ?? "", "note": str(r["note"]),
             "photos": (r["photos"] as? [String]) ?? [], "done": (r["done"] as? Bool) ?? false, "doneAt": n(r["doneAt"]),
             "createdAt": n(r["createdAt"]), "updatedAt": n(r["updatedAt"]), "answer": str(r["answer"]), "answeredAt": n(r["answeredAt"])]
        }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        let pages = ((doc["pages"] as? [[String: Any]]) ?? []).map { r -> [String: Any] in
            ["id": r["id"] as? String ?? "", "title": r["title"] as? String ?? "", "body": r["body"] as? String ?? "",
             "createdAt": n(r["createdAt"]), "updatedAt": n(r["updatedAt"])]
        }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        var dead: [String: Any] = [:]
        for (k, v) in (doc["dead"] as? [String: Any]) ?? [:] { dead[k] = n(v) }
        let obj: [String: Any] = ["items": items, "pages": pages, "dead": dead]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
