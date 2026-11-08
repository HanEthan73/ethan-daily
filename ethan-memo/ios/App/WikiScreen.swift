import SwiftUI
import SwiftData

// MARK: - 위키 목록

struct WikiScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \WikiPage.updatedAt, order: .reverse) private var pages: [WikiPage]
    @Query private var items: [Item]
    @State private var path: [String] = []
    @State private var q = ""
    @State private var tag: String?
    private var router = Router.shared

    private var filtered: [WikiPage] {
        var list = pages
        if let tag {
            let p = #"(^|\s)#"# + NSRegularExpression.escapedPattern(for: tag) + #"(?![0-9A-Za-z가-힣_\-])"#
            list = list.filter { $0.body.range(of: p, options: .regularExpression) != nil }
        }
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty { list = list.filter { $0.title.lowercased().contains(k) || $0.body.lowercased().contains(k) } }
        return list
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        TextField("페이지 검색 또는 새 제목", text: $q)
                            .submitLabel(.go)
                            .onSubmit { openOrCreate(q) }
                        Button("열기·만들기") { openOrCreate(q) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(q.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let tag {
                    Section {
                        Button { self.tag = nil } label: { Label("#\(tag) 필터 해제", systemImage: "xmark.circle.fill") }
                    }
                }
                if pages.isEmpty {
                    Section {
                        Text("제목을 적고 ‘열기·만들기’를 누르세요. 본문에 [[다른 페이지]]처럼 쓰면 서로 연결되고, 링크 주소·목록·표·체크박스는 자동으로 꾸며집니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } header: { Text("첫 페이지를 만들어 보세요").textCase(nil) }
                } else if filtered.isEmpty {
                    Section { Text("찾는 페이지가 없습니다. ‘열기·만들기’를 누르면 이 제목으로 새 페이지를 만듭니다.").font(.subheadline).foregroundStyle(.secondary) }
                } else {
                    Section("페이지 \(filtered.count)") {
                        ForEach(filtered) { p in
                            NavigationLink(value: p.uid) { row(p) }
                        }
                        .onDelete { idx in
                            for i in idx { ctx.delete(filtered[i]) }
                            try? ctx.save()
                        }
                    }
                }
            }
            .navigationTitle("위키")
            .navigationDestination(for: String.self) { uid in
                WikiPageView(uid: uid, open: open, onTag: { t in tag = t; path.removeAll() })
            }
            .onAppear(perform: handleRequest)
            .onChange(of: router.wikiTitle) { _, _ in handleRequest() }
        }
    }

    private func row(_ p: WikiPage) -> some View {
        let outN = WikiText.links(in: p.body).count
        let n = p.title.lowercased()
        let blN = pages.filter { $0.uid != p.uid && WikiText.links(in: $0.body).contains { $0.lowercased() == n } }.count
            + items.filter { WikiText.links(in: $0.text).contains { $0.lowercased() == n } }.count
        let meta = [Fmt.string(p.updatedAt, "M/d HH:mm") + " 수정", outN > 0 ? "연결 \(outN)" : "", blN > 0 ? "언급됨 \(blN)" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            Text(p.title).font(.body.weight(.semibold))
            let sn = WikiText.snippet(p.body)
            if !sn.isEmpty { Text(sn).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Text(meta).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func handleRequest() {
        guard let t = router.wikiTitle else { return }
        router.wikiTitle = nil
        path.removeAll()
        open(t)
    }

    private func openOrCreate(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        q = ""
        open(t)
    }

    /// 제목으로 열기 (없으면 만들기). 날짜면 캘린더로.
    private func open(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let d = WikiText.date(t) { router.go(date: d); return }
        if let p = pages.first(where: { $0.title.lowercased() == t.lowercased() }) {
            path.append(p.uid)
        } else {
            let p = WikiPage(title: t)
            ctx.insert(p)
            try? ctx.save()
            path.append(p.uid)
        }
    }
}

// MARK: - 페이지 보기

struct WikiPageView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var pages: [WikiPage]
    @Query private var items: [Item]
    let uid: String
    var open: (String) -> Void
    var onTag: (String) -> Void

    @State private var editing = false
    @State private var busy = false
    @State private var undo: String?
    @State private var errorText: String?
    @State private var confirmDelete = false

    private var page: WikiPage? { pages.first { $0.uid == uid } }

    var body: some View {
        Group {
            if let p = page {
                content(p)
            } else {
                ContentUnavailableView("페이지가 없습니다", systemImage: "doc.questionmark")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ p: WikiPage) -> some View {
        let outs = WikiText.links(in: p.body)
        let n = p.title.lowercased()
        let blPages = pages.filter { $0.uid != p.uid && WikiText.links(in: $0.body).contains { $0.lowercased() == n } }
        let blItems = items.filter { WikiText.links(in: $0.text).contains { $0.lowercased() == n } }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.string(p.updatedAt, "M월 d일 HH:mm") + " 수정")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(p.title).font(.title2.weight(.bold))
                }
                HStack(spacing: 8) {
                    Button("편집") { editing = true }.buttonStyle(.borderedProminent).disabled(busy)
                    Button { decorate(p) } label: {
                        if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("꾸미는 중…") } }
                        else { Label("Claude로 꾸미기", systemImage: "sparkles") }
                    }
                    .buttonStyle(.bordered).disabled(busy)
                    if let u = undo, !busy {
                        Button("되돌리기") { p.body = u; p.updatedAt = .now; undo = nil; try? ctx.save() }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)

                Group {
                    if p.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 6) {
                            Text("빈 페이지입니다").font(.headline)
                            Text("‘편집’으로 직접 쓰거나, ‘Claude로 꾸미기’를 누르면 이 제목으로 초안을 만들어 줍니다.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        MarkdownView(text: p.body,
                                     exists: { t in pages.contains { $0.title.lowercased() == t.lowercased() } },
                                     onToggle: { line in toggle(p, line) })
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))

                if !outs.isEmpty {
                    chipSection("이 페이지가 연결한 곳") {
                        ForEach(outs, id: \.self) { t in
                            let isNew = !WikiText.isDate(t) && !pages.contains { $0.title.lowercased() == t.lowercased() }
                            chip(WikiText.date(t).map(Fmt.short) ?? (isNew ? "\(t) (새 페이지)" : t), warn: isNew) { open(t) }
                        }
                    }
                }
                if !blPages.isEmpty || !blItems.isEmpty {
                    chipSection("이 페이지를 언급한 곳") {
                        ForEach(blPages) { q in chip(q.title) { open(q.title) } }
                        ForEach(blItems) { x in
                            chip("\(Fmt.short(x.day)) · \(x.kind.label) · \(WikiText.plain(x.text).prefix(20))") { Router.shared.go(date: x.day) }
                        }
                    }
                }
                Button("페이지 삭제", role: .destructive) { confirmDelete = true }
                    .font(.footnote)
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "haru-wiki" else { return .systemAction }
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            switch url.host {
            case "open": open(v)
            case "date": if let d = WikiText.date(v) { Router.shared.go(date: d) }
            case "tag": onTag(v)
            default: break
            }
            return .handled
        })
        .sheet(isPresented: $editing) { WikiEditView(page: p) }
        .alert("Claude로 꾸미지 못했습니다", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("이 페이지를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { ctx.delete(p); try? ctx.save(); dismiss() }
        }
    }

    private func chipSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) { content() }
        }
    }

    private func chip(_ text: String, warn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.footnote).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(warn ? Color.orange : Color.primary)
                .background(Capsule().fill(warn ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ p: WikiPage, _ line: Int) {
        var L = p.body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard line < L.count else { return }
        let s = L[line]
        if let r = s.range(of: #"\[( |x|X)\]"#, options: .regularExpression) {
            L[line] = s.replacingCharacters(in: r, with: s[r] == "[ ]" ? "[x]" : "[ ]")
            p.body = L.joined(separator: "\n")
            p.updatedAt = .now
            try? ctx.save()
        }
    }

    private func decorate(_ p: WikiPage) {
        guard Keychain.read() != nil else {
            errorText = "설정 탭에서 Claude API 키를 먼저 입력하세요."
            return
        }
        let titles = pages.filter { $0.uid != p.uid }.prefix(200).map(\.title).joined(separator: ", ")
        let prompt = """
        다음은 개인 위키의 "\(p.title)" 페이지입니다. \(p.body.isEmpty ? "아직 비어 있으니, 이 제목으로 쓸모 있는 위키 초안을 써 주세요." : "내용을 보기 좋은 위키 문서로 정리해 주세요.")
        규칙:
        - 한국어 마크다운만 출력. 앞뒤 설명을 붙이거나 전체를 코드블록으로 감싸지 말 것.
        - 맨 위 한 줄은 "> 한 줄 요약: …"
        - "## 소제목", "- 목록", 비교가 필요하면 "| 표 |", 해야 할 일은 "- [ ] 체크박스".
        - 원래 있던 정보, URL, [[링크]], #태그는 하나도 빼지 말 것. 모르는 사실을 지어내지 말 것.
        - 아래 기존 페이지 제목이 내용에 나오면 [[제목]]으로 감쌀 것: \(titles.isEmpty ? "(없음)" : titles)
        - 따로 페이지로 만들 만한 핵심 개념 2~3개도 [[개념]]으로 감쌀 것.
        - 페이지 제목은 다시 쓰지 말 것.

        내용:
        \(p.body.isEmpty ? "(비어 있음)" : p.body)
        """
        busy = true
        Task {
            do {
                var t = try await ClaudeClient.ask(prompt, maxTokens: 4000)
                t = t.replacingOccurrences(of: #"^```(?:markdown|md)?\s*\n"#, with: "", options: .regularExpression)
                t = t.replacingOccurrences(of: #"\n```\s*$"#, with: "", options: .regularExpression)
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    undo = p.body
                    p.body = t
                    p.updatedAt = .now
                    try? ctx.save()
                }
            } catch {
                errorText = (error as? ClaudeError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - 편집

struct WikiEditView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var pages: [WikiPage]
    @Query private var items: [Item]
    let page: WikiPage
    @State private var title: String
    @State private var text: String
    @State private var clash = false

    init(page: WikiPage) {
        self.page = page
        _title = State(initialValue: page.title)
        _text = State(initialValue: page.body)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("페이지 제목", text: $title)
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tool("[[링크]]") { text += "[[]]" }
                        tool("오늘") { text += "[[\(todayString)]]" }
                        tool("소제목") { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "## " }
                        tool("목록") { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "- " }
                        tool("체크") { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "- [ ] " }
                        tool("표") { text += "\n| 항목 | 내용 |\n|---|---|\n|  |  |\n" }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("여기에 쓰세요.\n\n[[다른 페이지]] → 페이지 연결\n[[2026-11-08]] → 그날 캘린더\n## 소제목   - 목록   - [ ] 체크   #태그\n링크 주소만 한 줄에 쓰면 카드로 꾸며집니다.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 21).padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .navigationTitle("위키 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("완료") { save() } }
            }
            .alert("같은 제목의 페이지가 이미 있습니다", isPresented: $clash) { Button("확인", role: .cancel) {} }
        }
    }

    private var todayString: String { Fmt.string(.now, "yyyy-MM-dd") }

    private func tool(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.bordered).controlSize(.small)
    }

    private func save() {
        let nt = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = nt.isEmpty ? page.title : nt
        if newTitle.lowercased() != page.title.lowercased() {
            if pages.contains(where: { $0.uid != page.uid && $0.title.lowercased() == newTitle.lowercased() }) {
                clash = true
                return
            }
            for q in pages where q.uid != page.uid {
                let b = WikiText.rename(q.body, from: page.title, to: newTitle)
                if b != q.body { q.body = b }
            }
            for x in items {
                let t = WikiText.rename(x.text, from: page.title, to: newTitle)
                if t != x.text { x.text = t }
            }
        }
        page.title = newTitle
        page.body = text
        page.updatedAt = .now
        Store.save(ctx)
        dismiss()
    }
}

// MARK: - 줄바꿈 칩 배치

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: maxW, height: nil))
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
