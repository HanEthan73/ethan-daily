import SwiftUI
import SwiftData
import Observation

// MARK: - GPT 챗봇: 말로 일정·할 일·메모를 등록/수정/삭제

struct ChatMsg: Codable, Identifiable {
    var id = UUID()
    var role: String          // "user" | "assistant"
    var content: String
    var acts: [String] = []
}

@MainActor
@Observable
final class ChatModel {
    static let shared = ChatModel()
    var msgs: [ChatMsg] = []
    var busy = false
    var error: String?
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
        사용자가 일정·약속·할 일·메모를 말하면 되묻지 말고 바로 add_items 도구로 등록하세요. 여러 건이면 한 번에 등록하세요.
        - "내일", "다음 주 화요일", "모레 3시" 같은 상대 표현은 오늘 기준으로 정확한 날짜(YYYY-MM-DD)로 바꾸세요.
        - 날짜·시간이 정해진 약속/만남/방문은 event, 해야 할 일은 todo(날짜 없으면 오늘), 단순 기록·아이디어는 memo.
        - 시간을 말하지 않았으면 time은 비우세요. 오전/오후 표현이 애매하면 상식적으로 판단하세요.
        - 수정·완료·삭제 요청은 아래 목록의 id로 update_item / delete_item을 쓰세요. 대상이 불분명하면 그때만 한 번 되물으세요.
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
                        "note": ["type": "string", "description": "세부 내용 (선택)"]
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
                let day = Self.parseDay(raw["date"] as? String) ?? Fmt.cal.startOfDay(for: .now)
                var end = Self.parseDay(raw["endDate"] as? String)
                if kind != .event || (end.map { $0 <= day } ?? true) { end = nil }
                let time = kind == .memo ? nil : Self.parseTime(raw["time"] as? String, on: day)
                let item = Item(kind: kind, day: day, endDay: end, time: time, text: text)
                item.note = (raw["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: 대화
    func send(_ text: String, ctx: ModelContext) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        msgs.append(ChatMsg(role: "user", content: t))
        busy = true; error = nil; persist()
        var acts: [String] = []
        var final = ""
        do {
            var api: [[String: Any]] = [["role": "system", "content": system(ctx: ctx)]]
            for m in msgs.suffix(16) {
                var c = m.content
                if !m.acts.isEmpty { c += "\n[앱에 처리됨: " + m.acts.joined(separator: " / ") + "]" }
                api.append(["role": m.role, "content": c])
            }
            for _ in 0..<5 {
                let r = try await GPTClient.raw(["messages": api, "tools": Self.tools])
                guard let choice = (r["choices"] as? [[String: Any]])?.first,
                      let m = choice["message"] as? [String: Any] else { break }
                if let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    api.append(m)
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
            self.error = (error as? GPTError)?.message ?? error.localizedDescription
            if !acts.isEmpty { msgs.append(ChatMsg(role: "assistant", content: "여기까지 처리했습니다.", acts: acts)) }
        }
        busy = false; persist()
    }
}

// MARK: - 화면

struct ChatScreen: View {
    @Environment(\.modelContext) private var ctx
    private var chat = ChatModel.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

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
            .navigationTitle("GPT 비서")
            .toolbar {
                if !chat.msgs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("대화 지우기") { chat.clear() }
                    }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("말로 등록하세요").font(.headline)
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
            Text(m.content)
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("예) 내일 오후 3시 치과 예약", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.pill))
            Button { send(draft) } label: {
                Text("보내기").font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .foregroundStyle(Theme.ctaInk)
                    .background(Capsule().fill(Theme.hi))
            }
            .buttonStyle(.borderless)
            .disabled(chat.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(chat.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ text: String) {
        let t = text
        draft = ""
        Task { await chat.send(t, ctx: ctx) }
    }
}
