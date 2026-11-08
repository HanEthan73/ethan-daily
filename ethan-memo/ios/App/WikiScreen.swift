import SwiftUI
import SwiftData

enum WikiRoute: Hashable {
    case page(String)
    case day(Date)
}

enum WikiMode: String, CaseIterable, Identifiable {
    case byDate = "날짜별", done = "완료", open = "남은 일", events = "일정", notes = "노트"
    var id: String { rawValue }
}

extension Fmt {
    static func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 위키: 할 일·일정 기록을 날짜별로 자동 정리 + 노트

struct WikiScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \WikiPage.updatedAt, order: .reverse) private var pages: [WikiPage]
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var path: [WikiRoute] = []
    @State private var q = ""
    @State private var tag: String?
    @State private var editing: Item?
    @AppStorage("wikiMode") private var modeRaw = WikiMode.byDate.rawValue
    private var router = Router.shared

    private var mode: WikiMode { WikiMode(rawValue: modeRaw) ?? .byDate }

    private var notes: [WikiPage] {
        var list = pages.filter { !WikiText.isDate($0.title) }
        if let tag {
            let p = #"(^|\s)#"# + NSRegularExpression.escapedPattern(for: tag) + #"(?![0-9A-Za-z가-힣_\-])"#
            list = list.filter { $0.body.range(of: p, options: .regularExpression) != nil }
        }
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty { list = list.filter { $0.title.lowercased().contains(k) || $0.body.lowercased().contains(k) } }
        return list
    }

    var body: some View {
        let todos = items.filter { $0.kind == .todo }
        let openN = todos.filter { !$0.done }.count
        let doneN = todos.count - openN
        let evN = items.filter { $0.kind == .event }.count
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 8) {
                        stat("남은 일", openN, Theme.warn) { modeRaw = WikiMode.open.rawValue }
                        stat("완료", doneN, Theme.todo) { modeRaw = WikiMode.done.rawValue }
                        stat("일정", evN, Theme.hi) { modeRaw = WikiMode.events.rawValue }
                        stat("노트", pages.filter { !WikiText.isDate($0.title) }.count, Theme.memo) { modeRaw = WikiMode.notes.rawValue }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    Picker("보기", selection: $modeRaw) {
                        ForEach(WikiMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                switch mode {
                case .byDate: byDate
                case .done: doneList(todos.filter(\.done))
                case .open: openList(todos.filter { !$0.done })
                case .events: eventList(items.filter { $0.kind == .event })
                case .notes: noteList
                }
            }
            .listStyle(.insetGrouped)
            .spaceGray()
            .navigationTitle("위키")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WikiRoute.self) { r in
                switch r {
                case .page(let uid):
                    WikiPageView(uid: uid, open: open, onTag: { t in tag = t; modeRaw = WikiMode.notes.rawValue; path.removeAll() })
                case .day(let d):
                    WikiDayView(day: d, open: open)
                }
            }
            .sheet(item: $editing) { EditSheet(item: $0) }
            .onAppear(perform: handleRequest)
            .onChange(of: router.wikiTitle) { _, _ in handleRequest() }
            .onChange(of: router.wikiDay) { _, _ in handleRequest() }
        }
    }

    // MARK: 통계 타일

    private func stat(_ label: String, _ n: Int, _ c: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n)").font(.system(size: 19, weight: .bold, design: .monospaced)).foregroundStyle(c)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: 날짜별

    @ViewBuilder private var byDate: some View {
        let byDay = Dictionary(grouping: items) { $0.day }
        let doneOn = doneCounts
        let notePages = Set(pages.filter { WikiText.isDate($0.title) }.compactMap { WikiText.date($0.title) })
        let dates = Set(byDay.keys).union(doneOn.keys).union(notePages).sorted(by: >)
        if dates.isEmpty {
            Section { empty("아직 기록이 없습니다. 할 일·일정을 추가하면 날짜별로 자동 정리됩니다.") }
        } else {
            Section {
                ForEach(dates.prefix(120), id: \.self) { d in
                    let list = byDay[d] ?? []
                    Button { path.append(.day(d)) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(Fmt.short(d)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    if Fmt.cal.isDateInToday(d) { Text("오늘").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.hi) }
                                    if let h = Holidays.shared.short(d) { Text(h).font(.system(size: 11)).foregroundStyle(Theme.sun) }
                                    if notePages.contains(d) { Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                Text(list.prefix(3).map { WikiText.plain($0.text) }.joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            counts(ev: list.filter { $0.kind == .event }.count,
                                   done: doneOn[d] ?? 0,
                                   open: list.filter { $0.kind == .todo && !$0.done }.count,
                                   memo: list.filter { $0.kind == .memo }.count)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowSurface()
                }
            } header: { Text("날짜를 누르면 그날의 정리 페이지").textCase(nil) }
        }
    }

    private var doneCounts: [Date: Int] {
        var m: [Date: Int] = [:]
        for i in items where i.kind == .todo && i.done {
            if let d = i.doneAt { m[Fmt.cal.startOfDay(for: d), default: 0] += 1 }
        }
        return m
    }

    private func counts(ev: Int, done: Int, open: Int, memo: Int) -> some View {
        HStack(spacing: 6) {
            if ev > 0 { pill("\(ev)", Theme.hi) }
            if done > 0 { pill("✓\(done)", Theme.todo) }
            if open > 0 { pill("○\(open)", Theme.warn) }
            if memo > 0 { pill("\(memo)", Theme.memo) }
        }
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(c)
            .background(Capsule().fill(c.opacity(0.14)))
    }

    // MARK: 완료 (완료한 날짜별)

    @ViewBuilder private func doneList(_ list: [Item]) -> some View {
        let g = Dictionary(grouping: list) { Fmt.cal.startOfDay(for: $0.doneAt ?? $0.day) }
        if g.isEmpty { Section { empty("완료한 할 일이 아직 없습니다. 할 일을 오른쪽으로 밀면 완료됩니다.") } }
        ForEach(g.keys.sorted(by: >), id: \.self) { d in
            Section {
                ForEach((g[d] ?? []).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }) { x in
                    recordRow(x, sub: "등록 \(Fmt.short(x.day))" + (Fmt.daysBetween(x.day, d) > 0 ? " · \(Fmt.daysBetween(x.day, d))일 걸림" : ""))
                }
            } header: { dayHeader(d, "완료 \(g[d]?.count ?? 0)") }
        }
    }

    // MARK: 남은 일 (등록한 날짜별)

    @ViewBuilder private func openList(_ list: [Item]) -> some View {
        let g = Dictionary(grouping: list) { $0.day }
        if g.isEmpty { Section { empty("남은 할 일이 없습니다.") } }
        ForEach(g.keys.sorted(by: >), id: \.self) { d in
            let late = Fmt.daysBetween(d, .now)
            Section {
                ForEach((g[d] ?? []).sorted { $0.createdAt > $1.createdAt }) { x in
                    recordRow(x, sub: late > 0 ? "\(late)일 지남" : nil, warn: late > 0)
                }
            } header: { dayHeader(d, "남은 \(g[d]?.count ?? 0)") }
        }
    }

    // MARK: 일정 (다가오는 것 먼저, 지난 것은 아래)

    @ViewBuilder private func eventList(_ list: [Item]) -> some View {
        let today = Fmt.cal.startOfDay(for: .now)
        let up = list.filter { $0.lastDay >= today }.sorted { ($0.day, Fmt.minutes($0.time)) < ($1.day, Fmt.minutes($1.time)) }
        let past = list.filter { $0.lastDay < today }.sorted { $0.day > $1.day }
        if list.isEmpty { Section { empty("등록한 일정이 없습니다. 캘린더에서 날짜를 꾹 누르세요.") } }
        if !up.isEmpty {
            Section { ForEach(up) { x in eventRow(x) } } header: { Text("다가오는 일정 \(up.count)").textCase(nil) }
        }
        if !past.isEmpty {
            Section { ForEach(past) { x in eventRow(x) } } header: { Text("지난 일정 \(past.count)").textCase(nil) }
        }
    }

    private func eventRow(_ x: Item) -> some View {
        Button { editing = x } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Text(Fmt.string(x.day, "M/d")).font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(Fmt.string(x.day, "E")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 42)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hiSoft))
                .foregroundStyle(Theme.hi)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WikiText.plain(x.text)).font(.system(size: 14.5, weight: .semibold))
                    let when = [x.isMultiDay ? "\(Fmt.short(x.day)) – \(Fmt.short(x.lastDay)) · \(Fmt.daysBetween(x.day, x.lastDay) + 1)일" : nil,
                                x.time.map { Fmt.time($0) }].compactMap { $0 }.joined(separator: " · ")
                    if !when.isEmpty { Text(when).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    if !x.note.isEmpty {
                        Text(WikiText.snippet(x.note)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    PhotoStrip(ids: x.photoIDs, size: 38)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowSurface()
    }

    private func recordRow(_ x: Item, sub: String?, warn: Bool = false) -> some View {
        Button { editing = x } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if x.done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.todo)
                } else {
                    Circle().fill(warn ? Theme.warn : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(WikiText.plain(x.text)).font(.system(size: 14.5))
                        .foregroundStyle(x.done ? .secondary : .primary)
                    if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(warn ? Theme.warn : Color.secondary) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowSurface()
    }

    private func dayHeader(_ d: Date, _ right: String) -> some View {
        Button { path.append(.day(d)) } label: {
            HStack {
                Text(Fmt.short(d)).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                if let h = Holidays.shared.short(d) { Text(h).font(.system(size: 11)).foregroundStyle(Theme.sun) }
                Spacer()
                Text(right).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundStyle(.secondary).rowSurface()
    }

    // MARK: 노트 (위키 페이지)

    @ViewBuilder private var noteList: some View {
        Section {
            HStack {
                TextField("노트 검색 또는 새 제목", text: $q)
                    .font(.system(size: 15))
                    .submitLabel(.go)
                    .onSubmit { openOrCreate(q) }
                Button("열기") { openOrCreate(q) }
                    .buttonStyle(.ink)
                    .disabled(q.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .rowSurface()
        }
        if let tag {
            Section {
                Button { self.tag = nil } label: { Label("#\(tag) 필터 해제", systemImage: "xmark.circle.fill") }.rowSurface()
            }
        }
        let list = notes
        if list.isEmpty {
            Section {
                empty("제목을 적고 ‘열기’를 누르세요. 본문에 [[다른 노트]]처럼 쓰면 서로 연결되고, [[2026-11-08]]처럼 날짜를 쓰면 그날 정리로 이어집니다.")
            }
        } else {
            Section("노트 \(list.count)") {
                ForEach(list) { p in
                    NavigationLink(value: WikiRoute.page(p.uid)) { row(p) }.rowSurface()
                }
                .onDelete { idx in
                    for i in idx { ctx.delete(list[i]) }
                    Store.save(ctx)
                }
            }
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
            Text(p.title).font(.system(size: 15, weight: .semibold))
            let sn = WikiText.snippet(p.body)
            if !sn.isEmpty { Text(sn).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
            Text(meta).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 이동

    private func handleRequest() {
        if let d = router.wikiDay {
            router.wikiDay = nil
            path = [.day(Fmt.cal.startOfDay(for: d))]
        }
        if let t = router.wikiTitle {
            router.wikiTitle = nil
            path.removeAll()
            open(t)
        }
    }

    private func openOrCreate(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        q = ""
        open(t)
    }

    /// 제목으로 열기 (없으면 만들기). 날짜면 그날 정리 페이지.
    private func open(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let d = WikiText.date(t) { path.append(.day(Fmt.cal.startOfDay(for: d))); return }
        if let p = pages.first(where: { $0.title.lowercased() == t.lowercased() }) {
            path.append(.page(p.uid))
        } else {
            let p = WikiPage(title: t)
            ctx.insert(p)
            Store.save(ctx)
            path.append(.page(p.uid))
        }
    }
}

// MARK: - 하루 정리 페이지 (자동 + 그날 노트 + Claude 정리)

struct WikiDayView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var pages: [WikiPage]
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    let day: Date
    var open: (String) -> Void
    @State private var editing: Item?
    @State private var editPage: WikiPage?
    @State private var busy = false
    @State private var errorText: String?

    private var key: String { Fmt.ymd(day) }
    private var note: WikiPage? { pages.first { $0.title == key } }

    var body: some View {
        let events = items.filter { $0.kind == .event && $0.covers(day) }
            .sorted { ($0.isMultiDay ? 0 : 1, Fmt.minutes($0.time)) < ($1.isMultiDay ? 0 : 1, Fmt.minutes($1.time)) }
        let done = items.filter { $0.kind == .todo && $0.done && Fmt.cal.isDate($0.doneAt ?? $0.day, inSameDayAs: day) }
        let open = items.filter { $0.kind == .todo && !$0.done && Fmt.cal.isDate($0.day, inSameDayAs: day) }
        let memos = items.filter { $0.kind == .memo && Fmt.cal.isDate($0.day, inSameDayAs: day) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(Fmt.string(day, "yyyy-MM-dd")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if let h = Holidays.shared.name(day) { Text(h).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sun) }
                    }
                    Text(Fmt.string(day, "M월 d일 EEEE")).font(.system(size: 22, weight: .bold))
                    HStack(spacing: 10) {
                        Text("일정 \(events.count)").foregroundStyle(Theme.hi)
                        Text("완료 \(done.count)").foregroundStyle(Theme.todo)
                        Text("남은 일 \(open.count)").foregroundStyle(open.isEmpty ? Color.secondary : Theme.warn)
                        Text("메모 \(memos.count)").foregroundStyle(Theme.memo)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                HStack(spacing: 8) {
                    Button { summarize(events: events, done: done, open: open, memos: memos) } label: {
                        if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("정리하는 중…") } }
                        else { Label("Claude 하루 정리", systemImage: "sparkles") }
                    }
                    .buttonStyle(.ink).disabled(busy)
                    Button { editPage = notePage() } label: { Label("노트", systemImage: "square.and.pencil") }
                        .buttonStyle(.bordered).tint(Theme.hi)
                    Button { Router.shared.go(date: day) } label: { Label("캘린더", systemImage: "calendar") }
                        .buttonStyle(.bordered).tint(.secondary)
                }
                .controlSize(.small)

                if let n = note, !n.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    box("하루 노트") {
                        MarkdownView(text: n.body, exists: { t in pages.contains { $0.title.lowercased() == t.lowercased() } })
                    }
                }
                if !events.isEmpty {
                    box("일정 \(events.count)", Theme.hi) {
                        ForEach(events) { x in
                            Button { editing = x } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(x.isMultiDay ? "\(Fmt.string(x.day, "M/d"))–\(Fmt.string(x.lastDay, "M/d"))" : (x.time.map(Fmt.time) ?? "종일"))
                                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.hi)
                                        Text(WikiText.plain(x.text)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                                    }
                                    if !x.note.isEmpty {
                                        MarkdownView(text: x.note).font(.system(size: 13.5))
                                            .padding(.leading, 10)
                                            .overlay(alignment: .leading) { Rectangle().fill(Theme.hi.opacity(0.5)).frame(width: 2) }
                                    }
                                    PhotoStrip(ids: x.photoIDs, size: 54)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !done.isEmpty { list("완료한 일 \(done.count)", done, Theme.todo) }
                if !open.isEmpty { list("남은 일 \(open.count)", open, Theme.warn) }
                if !memos.isEmpty { list("메모 \(memos.count)", memos, Theme.memo) }
                if events.isEmpty && done.isEmpty && open.isEmpty && memos.isEmpty && (note?.body.isEmpty ?? true) {
                    Text("이 날은 기록이 없습니다. ‘노트’로 그날 메모를 남길 수 있습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "haru-wiki" else { return .systemAction }
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            if url.host == "open" || url.host == "date" { self.open(v) }
            return .handled
        })
        .sheet(item: $editing) { EditSheet(item: $0) }
        .sheet(item: $editPage) { WikiEditView(page: $0) }
        .alert("Claude로 정리하지 못했습니다", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func box<C: View>(_ title: String, _ c: Color = .secondary, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
    }

    private func list(_ title: String, _ xs: [Item], _ c: Color) -> some View {
        box(title, c) {
            ForEach(xs) { x in
                Button { editing = x } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if x.done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.todo)
                        } else {
                            Circle().fill(c).frame(width: 5, height: 5)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WikiText.plain(x.text)).font(.system(size: 14.5)).foregroundStyle(.primary)
                            if !x.note.isEmpty { Text(WikiText.snippet(x.note)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                            if x.done, !Fmt.cal.isDate(x.day, inSameDayAs: day) {
                                Text("등록 \(Fmt.short(x.day))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            PhotoStrip(ids: x.photoIDs, size: 40)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notePage() -> WikiPage {
        if let n = note { return n }
        let p = WikiPage(title: key)
        ctx.insert(p)
        Store.save(ctx)
        return p
    }

    private func summarize(events: [Item], done: [Item], open: [Item], memos: [Item]) {
        guard Keychain.read() != nil else { errorText = "설정 탭에서 Claude API 키를 먼저 입력하세요."; return }
        func line(_ x: Item, _ pre: String) -> String {
            var s = "\(pre) \(WikiText.plain(x.text))"
            if let t = x.time { s += " (\(Fmt.time(t)))" }
            if x.isMultiDay { s += " (\(Fmt.ymd(x.day))~\(Fmt.ymd(x.lastDay)))" }
            if !x.note.isEmpty { s += "\n  상세: " + x.note.replacingOccurrences(of: "\n", with: "\n  ") }
            return s
        }
        func block(_ title: String, _ xs: [Item], _ pre: String) -> String? {
            if xs.isEmpty { return nil }
            let body: String = xs.map { line($0, pre) }.joined(separator: "\n")
            return title + ":\n" + body
        }
        var blocks: [String] = []
        if let b = block("일정", events, "-") { blocks.append(b) }
        if let b = block("완료한 일", done, "- [x]") { blocks.append(b) }
        if let b = block("남은 일", open, "- [ ]") { blocks.append(b) }
        if let b = block("메모", memos, "-") { blocks.append(b) }
        let parts: String = blocks.joined(separator: "\n\n")
        let old: String = note?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let oldPart: String = old.isEmpty ? "" : "\n기존 노트:\n" + old
        let record: String = parts.isEmpty ? "(기록 없음)" : parts
        let prompt = """
        다음은 \(key) 하루의 기록입니다. 개인 위키에 남길 '하루 정리' 노트를 한국어 마크다운으로 써 주세요.
        규칙:
        - 앞뒤 설명 없이 마크다운만. 전체를 코드블록으로 감싸지 말 것.
        - 맨 위 한 줄은 "> 한 줄 요약: …"
        - 있는 항목만 섹션으로: "## 일정", "## 완료", "## 남은 일", "## 메모". 완료는 "- [x]", 남은 일은 "- [ ]".
        - 상세 내용이 있으면 항목 아래에 들여쓴 짧은 요점으로.
        - 마지막에 "## 다음에 할 것" 섹션으로 남은 일 기준 제안 2~3개.
        - 기록에 없는 사실을 지어내지 말 것. 기존 노트의 내용은 빼지 말고 살릴 것.

        기록:
        \(record)
        \(oldPart)
        """
        busy = true
        Task {
            do {
                var t = try await ClaudeClient.ask(prompt, maxTokens: 3000)
                t = t.replacingOccurrences(of: #"^```(?:markdown|md)?\s*\n"#, with: "", options: .regularExpression)
                t = t.replacingOccurrences(of: #"\n```\s*$"#, with: "", options: .regularExpression)
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    let p = notePage()
                    p.body = t
                    Store.save(ctx)
                }
            } catch {
                errorText = (error as? ClaudeError)?.message ?? error.localizedDescription
            }
            busy = false
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
                    Button("편집") { editing = true }.buttonStyle(.ink).disabled(busy)
                    Button { decorate(p) } label: {
                        if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("꾸미는 중…") } }
                        else { Label("Claude로 꾸미기", systemImage: "sparkles") }
                    }
                    .buttonStyle(.bordered).tint(Theme.hi).disabled(busy)
                    if let u = undo, !busy {
                        Button("되돌리기") { p.body = u; p.updatedAt = .now; undo = nil; Store.save(ctx) }
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
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 0.5))

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
                            chip("\(Fmt.short(x.day)) · \(x.kind.label) · \(WikiText.plain(x.text).prefix(20))") { open(Fmt.ymd(x.day)) }
                        }
                    }
                }
                Button("페이지 삭제", role: .destructive) { confirmDelete = true }
                    .font(.footnote)
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "haru-wiki" else { return .systemAction }
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            switch url.host {
            case "open": open(v)
            case "date": open(v)
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
            Button("삭제", role: .destructive) { ctx.delete(p); Store.save(ctx); dismiss() }
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
                .foregroundStyle(warn ? Theme.warn : Color.primary)
                .background(Capsule().fill(warn ? Theme.warn.opacity(0.15) : Theme.hiSoft))
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
            Store.save(ctx)
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
                    Store.save(ctx)
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
