import SwiftUI
import SwiftData
import Observation
import Speech
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - GPT 챗봇: 말로 일정·할 일·메모를 등록/수정/삭제

struct ChatMsg: Codable, Identifiable {
    var id = UUID()
    var role: String          // "user" | "assistant"
    var content: String
    var acts: [String] = []
    /// 무료 모드에서 GPT가 필요한 질문이면 ChatGPT로 열 문장
    var gpt: String? = nil
    /// 첨부한 사진(PhotoStore ID)과 파일 이름
    var photos: [String]? = nil
    var files: [String]? = nil
}

/// 챗봇에 첨부한 파일 (보낼 때만 메모리에 둠)
struct ChatFile: Identifiable {
    let id = UUID()
    let name: String
    let kind: String      // text | pdf
    var text: String? = nil
    var data: Data? = nil
}

@MainActor
@Observable
final class ChatModel {
    static let shared = ChatModel()
    var msgs: [ChatMsg] = []
    var busy = false
    var error: String?
    var pendingPhotos: [String] = []
    var pendingFiles: [ChatFile] = []
    @ObservationIgnored private var curPhotos: [String] = []
    @ObservationIgnored private var curFiles: [ChatFile] = []
    private let storeKey = "chat.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let m = try? JSONDecoder().decode([ChatMsg].self, from: d) { msgs = Array(m.suffix(40)) }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(Array(msgs.suffix(40))) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
    func clear() { msgs = []; error = nil; persist() }

    // MARK: 날짜 도우미
    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Fmt.cal
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    private static func parseDay(_ s: String?) -> Date? {
        guard let s, s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return dayFormatter().date(from: s)
    }
    private static func parseTime(_ s: String?, on day: Date) -> Date? {
        guard let s, s.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Fmt.cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: day)
    }
    private static func ymd(_ d: Date) -> String { dayFormatter().string(from: d) }
    /// AI가 연도를 틀려 한참 지난 날짜를 주면 1년 뒤로 바로잡음
    private static func fixYear(_ d: Date?) -> Date? {
        guard let d else { return nil }
        let lo = Fmt.addDays(Fmt.cal.startOfDay(for: .now), -31)
        guard d < lo, let n = Fmt.cal.date(byAdding: .year, value: 1, to: d) else { return d }
        return (n >= lo && n <= Fmt.addDays(lo, 400)) ? n : d
    }

    // MARK: 시스템 프롬프트 (오늘 날짜 + 현재 항목 목록)
    private func system(ctx: ModelContext) -> String {
        let today = Fmt.cal.startOfDay(for: .now)
        let lo = Fmt.addDays(today, -7), hi = Fmt.addDays(today, 45)
        let items = ((try? ctx.fetch(FetchDescriptor<Item>())) ?? [])
            .filter { ($0.kind == .todo && !$0.done) || ($0.day >= lo && $0.day <= hi) }
            .sorted { ($0.day, Fmt.minutes($0.time)) < ($1.day, Fmt.minutes($1.time)) }
            .prefix(120)
        let kindName: [Kind: String] = [.event: "일정", .todo: "할일", .memo: "메모"]
        let rows = items.map { i -> String in
            let d = Self.ymd(i.day) + (i.endDay.map { "~" + Self.ymd($0) } ?? "")
            let t = i.time.map(Fmt.time) ?? "-"
            let txt = WikiText.plain(i.text).replacingOccurrences(of: "\n", with: " ").prefix(60)
            return "\(i.uid)|\(kindName[i.kind] ?? "")|\(d)|\(t)|\(txt)" + (i.done ? "|완료" : "")
        }
        return """
        당신은 ETHAN MEMO의 개인 비서 챗봇입니다. 한국어로 짧고 친근하게 답하세요.
        오늘은 \(Self.ymd(today)) (\(Fmt.string(today, "E"))요일)입니다. 시간대는 한국(KST).
        올해는 \(Self.ymd(today).prefix(4))년입니다. 날짜 계산 예: 내일=\(Self.ymd(Fmt.addDays(today, 1))), 다음 주 같은 요일=\(Self.ymd(Fmt.addDays(today, 7))), 1개월 뒤=\(Self.ymd(Fmt.cal.date(byAdding: .month, value: 1, to: today) ?? today)), 3개월 뒤=\(Self.ymd(Fmt.cal.date(byAdding: .month, value: 3, to: today) ?? today)). 미래 날짜를 과거 연도로 쓰지 마세요.
        사용자가 일정·약속·할 일·메모를 말하면 되묻지 말고 바로 add_items 도구로 등록하세요. 여러 건이면 한 번에 등록하세요.
        - "내일", "다음 주 화요일", "모레 3시" 같은 상대 표현은 오늘 기준으로 정확한 날짜(YYYY-MM-DD)로 바꾸세요.
        - 날짜·시간이 정해진 약속/만남/방문은 event, 해야 할 일은 todo(날짜 없으면 오늘), 단순 기록·아이디어는 memo.
        - 시간을 말하지 않았으면 time은 비우세요. 오전/오후 표현이 애매하면 상식적으로 판단하세요.
        - 수정·완료·삭제 요청은 아래 목록의 id로 update_item / delete_item을 쓰세요. 대상이 불분명하면 그때만 한 번 되물으세요.
        - 사용자가 사진·파일을 첨부하면 내용을 읽고 답하세요. 청첩장·예약 문자·티켓·시간표·공지처럼 일정이나 할 일이 보이면 날짜·시간을 뽑아 바로 등록하고, 그 사진을 항목에 남기려면 attach_photos=true.
        - 일정 조회·추천 질문에는 아래 목록을 보고 답하세요. 등록이 끝나면 무엇을 언제로 등록했는지 한두 줄로 알려 주세요.
        현재 항목 (id|종류|날짜|시간|제목):
        \(rows.isEmpty ? "(없음)" : rows.joined(separator: "\n"))
        """
    }

    // MARK: 도구 정의
    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "add_items",
            "description": "사용자의 일정·할 일·메모를 앱에 등록한다. 여러 개를 한 번에 등록할 수 있다.",
            "parameters": [
                "type": "object",
                "properties": ["items": ["type": "array", "items": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["event", "todo", "memo"], "description": "event=특정 날짜(시간)에 있는 약속·일정, todo=해야 할 일, memo=기록·생각"],
                        "text": ["type": "string", "description": "제목(짧게)"],
                        "date": ["type": "string", "description": "YYYY-MM-DD. 기간 일정이면 시작일. 말하지 않았으면 오늘"],
                        "endDate": ["type": "string", "description": "기간 일정의 종료일 YYYY-MM-DD (선택)"],
                        "time": ["type": "string", "description": "HH:MM 24시간제 (선택, 모르면 비움)"],
                        "note": ["type": "string", "description": "세부 내용 (선택)"],
                        "attach_photos": ["type": "boolean", "description": "사용자가 이번 메시지에 첨부한 사진을 이 항목에 붙일지. 사진이 있고 관련된 항목이면 true"]
                    ],
                    "required": ["type", "text", "date"]
                ]]],
                "required": ["items"]
            ]
        ]],
        ["type": "function", "function": [
            "name": "update_item",
            "description": "이미 있는 항목을 수정한다(완료 처리 포함). id는 항목 목록에 있는 값.",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"], "text": ["type": "string"], "date": ["type": "string"],
                    "endDate": ["type": "string"], "time": ["type": "string"], "note": ["type": "string"],
                    "type": ["type": "string", "enum": ["event", "todo", "memo"]], "done": ["type": "boolean"]
                ],
                "required": ["id"]
            ]
        ]],
        ["type": "function", "function": [
            "name": "delete_item",
            "description": "항목을 삭제한다. 사용자가 분명히 지우라고 했을 때만.",
            "parameters": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
        ]]
    ]

    // MARK: 도구 실행
    private func run(_ name: String, _ a: [String: Any], ctx: ModelContext) -> (result: [String: Any], acts: [String]) {
        let icon: [String: String] = ["event": "📅", "todo": "☑️", "memo": "📝"]
        switch name {
        case "add_items":
            var created: [[String: Any]] = []
            var acts: [String] = []
            for raw in (a["items"] as? [[String: Any]]) ?? [] {
                let text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let kind = Kind(rawValue: raw["type"] as? String ?? "") ?? .memo
                let day = Self.fixYear(Self.parseDay(raw["date"] as? String)) ?? Fmt.cal.startOfDay(for: .now)
                var end = Self.fixYear(Self.parseDay(raw["endDate"] as? String))
                if kind != .event || (end.map { $0 <= day } ?? true) { end = nil }
                let time = kind == .memo ? nil : Self.parseTime(raw["time"] as? String, on: day)
                let item = Item(kind: kind, day: day, endDay: end, time: time, text: text)
                item.note = (raw["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if (raw["attach_photos"] as? Bool) == true && !curPhotos.isEmpty { item.photoIDs = curPhotos }
                ctx.insert(item)
                created.append(["id": item.uid, "type": kind.rawValue, "date": Self.ymd(day), "text": text])
                acts.append("\(icon[kind.rawValue] ?? "") \(Fmt.short(day))\(time.map { " " + Fmt.time($0) } ?? "") · \(text)")
            }
            Store.save(ctx)
            return (["ok": true, "created": created], acts)
        case "update_item":
            guard let id = a["id"] as? String, let item = findItem(id, ctx) else { return (["ok": false, "error": "없는 id"], []) }
            if let t = a["text"] as? String, !t.isEmpty { item.text = t }
            if let k = Kind(rawValue: a["type"] as? String ?? "") { item.kind = k }
            if let d = Self.parseDay(a["date"] as? String) { item.day = d }
            if a["endDate"] != nil {
                let e = Self.parseDay(a["endDate"] as? String)
                item.endDay = (e.map { $0 > item.day } ?? false) ? e : nil
            }
            if a["time"] != nil { item.time = Self.parseTime(a["time"] as? String, on: item.day) }
            else if let t = item.time, a["date"] != nil {
                let c = Fmt.cal.dateComponents([.hour, .minute], from: t)
                item.time = Fmt.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: item.day)
            }
            if let n = a["note"] as? String { item.note = n }
            if let dn = a["done"] as? Bool { item.done = dn; item.doneAt = dn ? .now : nil }
            Store.save(ctx)
            return (["ok": true, "id": id, "text": item.text], ["✏️ 수정 · \(item.text) (\(Fmt.short(item.day)))"])
        case "delete_item":
            guard let id = a["id"] as? String, let item = findItem(id, ctx) else { return (["ok": false, "error": "없는 id"], []) }
            let t = item.text
            ctx.delete(item)
            Store.save(ctx)
            return (["ok": true, "deleted": t], ["🗑 삭제 · \(t)"])
        default:
            return (["ok": false, "error": "알 수 없는 도구"], [])
        }
    }
    private func findItem(_ id: String, _ ctx: ModelContext) -> Item? {
        var d = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == id })
        d.fetchLimit = 1
        return try? ctx.fetch(d).first
    }

    // MARK: 무료 모드 (API 키 없음)
    private func freeReply(_ t: String, ctx: ModelContext) {
        defer { persist() }
        if t.isEmpty && !curPhotos.isEmpty {
            let r = run("add_items", ["items": [["type": "memo", "text": "사진 메모", "date": "", "attach_photos": true]]], ctx: ctx)
            msgs.append(ChatMsg(role: "assistant", content: "사진을 오늘 메모로 저장했어요 📷 (기본 모드는 사진 내용을 읽지 못해요 · Gemini 키를 넣으면 사진 속 일정도 자동 등록)", acts: r.acts))
            return
        }
        if let r = QuickChat.listRange(t) {
            let all = ((try? ctx.fetch(FetchDescriptor<Item>())) ?? [])
                .filter { $0.day <= r.to && $0.lastDay >= r.from && !($0.kind == .todo && $0.done) }
                .sorted { ($0.day, Fmt.minutes($0.time)) < ($1.day, Fmt.minutes($1.time)) }
            if all.isEmpty { msgs.append(ChatMsg(role: "assistant", content: "\(r.label)에 등록된 일정·할 일·메모가 없습니다.")); return }
            let ic: [Kind: String] = [.event: "📅", .todo: "☑️", .memo: "📝"]
            let lines = all.prefix(40).map { "- \(Fmt.short($0.day))\($0.time.map { " " + Fmt.time($0) } ?? "") · \(ic[$0.kind] ?? "") \(WikiText.plain($0.text).replacingOccurrences(of: "\n", with: " ").prefix(50))" }
            msgs.append(ChatMsg(role: "assistant", content: "**\(r.label)** 일정·할 일 \(all.count)건\n\n" + lines.joined(separator: "\n")))
            return
        }
        if QuickChat.isEditCommand(t) {
            msgs.append(ChatMsg(role: "assistant", content: "무료 모드에서는 **등록**만 말로 할 수 있어요. 수정·삭제·완료는 카드를 밀거나 눌러서 하세요. (OpenAI 키를 넣으면 말로도 가능합니다)"))
            return
        }
        if QuickChat.isQuestion(t) {
            msgs.append(ChatMsg(role: "assistant", content: "질문 답변은 GPT가 필요해요. 아래 버튼으로 **ChatGPT 앱·웹(무료 계정)**에서 바로 물어볼 수 있어요.", gpt: t))
            return
        }
        let parsed = QuickChat.parse(t)
        if parsed.isEmpty {
            msgs.append(ChatMsg(role: "assistant", content: "이해하지 못했어요. “내일 오후 3시 치과”, “금요일까지 보고서 제출”처럼 말해 보세요."))
            return
        }
        var items: [[String: Any]] = parsed.map { ["type": $0.type, "text": $0.text, "date": $0.date, "time": $0.time] }
        if !curPhotos.isEmpty { items[0]["attach_photos"] = true }
        let r = run("add_items", ["items": items], ctx: ctx)
        msgs.append(ChatMsg(role: "assistant", content: "등록했어요 ✅ (기본 모드)", acts: r.acts))
    }

    /// 이번 메시지의 사진·파일을 AI가 읽을 수 있는 형태로
    private func parts(_ t: String) -> [[String: Any]] {
        var txt = t.isEmpty ? "첨부한 내용을 보고 정리해 주세요. 일정이나 할 일이 있으면 등록해 주세요." : t
        for f in curFiles where f.kind == "text" { txt += "\n\n[첨부 파일: \(f.name)]\n" + (f.text ?? "") }
        var out: [[String: Any]] = [["type": "text", "text": txt]]
        for id in curPhotos {
            if let d = try? Data(contentsOf: PhotoStore.url(id)) {
                out.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
            }
        }
        let gem = GPTClient.config()?.model.isGemini ?? true
        for f in curFiles where f.kind == "pdf" {
            guard let d = f.data else { continue }
            let url = "data:application/pdf;base64," + d.base64EncodedString()
            out.append(gem ? ["type": "image_url", "image_url": ["url": url]]
                           : ["type": "file", "file": ["filename": f.name, "file_data": url]])
        }
        return out
    }

    /// 파일 앱에서 고른 파일 읽기
    func addFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { error = "파일을 읽지 못했습니다: \(url.lastPathComponent)"; return }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            if let id = PhotoStore.add(d) { pendingPhotos.append(id) }
        } else if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            guard d.count < 15_000_000 else { error = "PDF가 너무 커요 (15MB 이하)"; return }
            pendingFiles.append(ChatFile(name: name, kind: "pdf", data: d))
        } else if let s = String(data: d, encoding: .utf8) {
            pendingFiles.append(ChatFile(name: name, kind: "text", text: String(s.prefix(60000))))
        } else {
            error = "이 형식은 아직 못 읽어요. 사진·PDF·텍스트(txt·md·csv·json)를 넣어 주세요."
        }
    }

    // MARK: 대화
    func send(_ text: String, ctx: ModelContext) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pendingPhotos.isEmpty || !pendingFiles.isEmpty, !busy else { return }
        curPhotos = pendingPhotos; curFiles = pendingFiles
        pendingPhotos = []; pendingFiles = []
        msgs.append(ChatMsg(role: "user", content: t,
                            photos: curPhotos.isEmpty ? nil : curPhotos,
                            files: curFiles.isEmpty ? nil : curFiles.map(\.name)))
        error = nil
        defer { curPhotos = []; curFiles = [] }
        if GPTClient.config() == nil {
            if !curFiles.isEmpty { error = "파일 내용 읽기는 AI 키(무료 Gemini)가 필요해요. 설정 → AI · 챗봇에서 넣어 주세요." }
            freeReply(t, ctx: ctx); return
        }
        busy = true; persist()
        var acts: [String] = []
        var final = ""
        do {
            var api: [[String: Any]] = [["role": "system", "content": system(ctx: ctx)]]
            for m in msgs.suffix(16) {
                var c = m.content
                if let p = m.photos, !p.isEmpty { c += "\n[사진 \(p.count)장 첨부]" }
                if let f = m.files, !f.isEmpty { c += "\n[파일: " + f.joined(separator: ", ") + "]" }
                if !m.acts.isEmpty { c += "\n[앱에 처리됨: " + m.acts.joined(separator: " / ") + "]" }
                api.append(["role": m.role, "content": c])
            }
            if !curPhotos.isEmpty || !curFiles.isEmpty, var last = api.last, (last["role"] as? String) == "user" {
                last["content"] = parts(t)
                api[api.count - 1] = last
            }
            for _ in 0..<5 {
                let r = try await GPTClient.raw(["messages": api, "tools": Self.tools])
                guard let choice = (r["choices"] as? [[String: Any]])?.first,
                      let m = choice["message"] as? [String: Any] else { break }
                if let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var am = m
                    am["content"] = (m["content"] as? String) ?? ""
                    api.append(am)
                    for c in calls {
                        let fn = c["function"] as? [String: Any] ?? [:]
                        let args = (try? JSONSerialization.jsonObject(with: Data((fn["arguments"] as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
                        let out = run(fn["name"] as? String ?? "", args, ctx: ctx)
                        acts += out.acts
                        let data = (try? JSONSerialization.data(withJSONObject: out.result)) ?? Data("{}".utf8)
                        api.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "", "content": String(decoding: data, as: UTF8.self)])
                    }
                    continue
                }
                final = (m["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            if final.isEmpty { final = acts.isEmpty ? "답을 받지 못했습니다. 다시 말씀해 주세요." : "처리했습니다." }
            msgs.append(ChatMsg(role: "assistant", content: final, acts: acts))
        } catch {
            let ge = error as? GPTError
            self.error = ge?.message ?? error.localizedDescription
            if ge?.noCredits == true { freeReply(t, ctx: ctx) }
            if !acts.isEmpty { msgs.append(ChatMsg(role: "assistant", content: "여기까지 처리했습니다.", acts: acts)) }
        }
        busy = false; persist()
    }
}

// MARK: - 화면

struct ChatScreen: View {
    @Environment(\.modelContext) private var ctx
    var onClose: () -> Void
    init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }
    private var chat = ChatModel.shared
    @State private var draft = ""
    @State private var speech = SpeechInput()
    @AppStorage("gptModel") private var modelRaw = GPTModel.gemFlash.rawValue
    @FocusState private var focused: Bool
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    private let examples = ["내일 저녁 7시 회식", "이번 주 할 일 정리해줘", "보고서 제출 완료 처리"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chat.msgs.isEmpty { intro }
                        ForEach(chat.msgs) { m in bubble(m).id(m.id) }
                        if chat.busy {
                            Text("생각하는 중…").font(.subheadline).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 20).fill(Theme.pill))
                        }
                        if let e = chat.error {
                            Text(e).font(.subheadline)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.warn.opacity(0.2)))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.msgs.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                .onChange(of: chat.busy) { _, _ in withAnimation { proxy.scrollTo("end") } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .spaceGray()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { modelMenu }
                ToolbarItem(placement: .topBarLeading) {
                    Button { speech.stop(); onClose() } label: { Image(systemName: "xmark") }
                }
                if !chat.msgs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("대화 지우기") { chat.clear() }
                    }
                }
            }
        }
    }

    /// ChatGPT 앱처럼 위쪽 모델 이름 + ⌄ 를 누르면 모델 목록
    private var modelMenu: some View {
        let cur = GPTClient.config()?.model ?? (GPTModel(rawValue: modelRaw) ?? .gemFlash)
        return Menu {
            ForEach(GPTModel.allCases) { m in
                Button {
                    modelRaw = m.rawValue
                    UserDefaults.standard.removeObject(forKey: "gemok." + m.rawValue)
                } label: {
                    if m == cur { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    Text(m.desc + (m.hasKey ? "" : " · 🔑 키 필요"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(cur.title).font(.system(size: 17, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("말로 등록하세요").font(.headline)
            if GPTClient.config() == nil {
                Text("🆓 지금은 기본 모드: “내일 오후 3시 치과”처럼 말하면 바로 등록돼요.\n구글 로그인으로 무료 Gemini 키를 넣으면 질문 답변·말로 수정·삭제까지 돼요 (충전·카드 없음). ⚙ 설정 → Gemini API 키")
                    .font(.footnote).foregroundStyle(Theme.hi)
            }
            Text("“내일 오후 3시 남희이태원 미팅”, “금요일까지 보고서 제출”, “다음 주 월~수 부산 출장”처럼 말하면 일정·할 일·메모로 알아서 등록합니다. 수정·완료·삭제도 말로 하면 됩니다.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(examples, id: \.self) { ex in
                    Button { send(ex) } label: {
                        Text(ex).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.hiSoft))
                            .foregroundStyle(Theme.hi)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.pill))
    }

    @ViewBuilder private func bubble(_ m: ChatMsg) -> some View {
        if m.role == "user" {
            VStack(alignment: .trailing, spacing: 6) {
                if let p = m.photos, !p.isEmpty { PhotoStrip(ids: p, size: 84) }
                if let f = m.files, !f.isEmpty {
                    ForEach(f, id: \.self) { n in Text("📎 " + n).font(.footnote) }
                }
                if !m.content.isEmpty { Text(m.content) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(Theme.ctaInk)
            .background(RoundedRectangle(cornerRadius: 20).fill(Theme.hi))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(CardMarkdown.attributed(m.content))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Theme.pill))
                if let q = m.gpt {
                    Button { GPTLink.open(q) } label: {
                        Text("ChatGPT로 물어보기 ↗").font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(Theme.ctaInk)
                            .background(Capsule().fill(Theme.hi))
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(m.acts, id: \.self) { a in
                    Text(a).font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            attachStrip
            composerRow
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self), let id = PhotoStore.add(d) { chat.pendingPhotos.append(id) }
                }
                photoItems = []
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.pdf, .plainText, .text, .commaSeparatedText, .json, .image], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { chat.addFile(u) } }
        }
    }

    @ViewBuilder private var attachStrip: some View {
        if !chat.pendingPhotos.isEmpty || !chat.pendingFiles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chat.pendingPhotos, id: \.self) { id in
                        ZStack(alignment: .topTrailing) {
                            PhotoThumb(id: id, size: 58)
                            Button { chat.pendingPhotos.removeAll { $0 == id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    ForEach(chat.pendingFiles) { f in
                        HStack(spacing: 6) {
                            Text((f.kind == "pdf" ? "📄 " : "📝 ") + f.name).font(.footnote).lineLimit(1)
                            Button { chat.pendingFiles.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.pill))
                    }
                }
            }
        }
    }

    /// 입력칸은 한 줄 전체, 버튼은 그 아래 줄
    private var composerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("무엇이든 말하거나 물어보세요", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.pill))
            HStack(spacing: 8) {
                Menu {
                    Button { pickingPhotos = true } label: { Label("사진", systemImage: "photo.on.rectangle") }
                    Button { pickingFiles = true } label: { Label("파일 (PDF·텍스트)", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.hi)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("사진·파일 첨부")
                Button {
                    focused = false
                    speech.toggle(base: draft) { draft = $0 }
                } label: {
                    Image(systemName: speech.listening ? "waveform" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(speech.listening ? Color.white : Theme.hi)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(speech.listening ? Color.red : Theme.hiSoft))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("음성으로 말하기")
                Spacer()
                Button { send(draft) } label: {
                    Text("보내기").font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .foregroundStyle(Theme.ctaInk)
                        .background(Capsule().fill(Theme.hi))
                }
                .buttonStyle(.borderless)
                .disabled(chat.busy || !canSend)
                .opacity(chat.busy || !canSend ? 0.5 : 1)
            }
        }
        .alert("음성 입력", isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.error = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(speech.error ?? "") }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingPhotos.isEmpty || !chat.pendingFiles.isEmpty
    }

    private func send(_ text: String) {
        let t = text
        speech.stop()
        draft = ""
        Task { await chat.send(t, ctx: ctx) }
    }
}


// MARK: - 음성 입력 (iOS 음성 인식, 한국어)

@MainActor
@Observable
final class SpeechInput {
    var listening = false
    var error: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))

    func toggle(base: String, onUpdate: @escaping (String) -> Void) {
        if listening { stop(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "설정 앱에서 이 앱의 ‘음성 인식’을 허용해 주세요."; return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else { self.error = "설정 앱에서 이 앱의 ‘마이크’를 허용해 주세요."; return }
                        self.start(base: base, onUpdate: onUpdate)
                    }
                }
            }
        }
    }

    nonisolated private static func tap(_ input: AVAudioInputNode, _ req: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
    }

    private func start(base: String, onUpdate: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { error = "지금은 음성 인식을 쓸 수 없습니다."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            Self.tap(engine.inputNode, req)
            engine.prepare()
            try engine.start()
            listening = true
            let prefix = base.trimmingCharacters(in: .whitespacesAndNewlines)
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let r = result {
                        onUpdate((prefix.isEmpty ? "" : prefix + " ") + r.bestTranscription.formattedString)
                    }
                    if err != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            self.error = "마이크를 시작하지 못했습니다."
            stop()
        }
    }

    func stop() {
        guard listening || request != nil else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
