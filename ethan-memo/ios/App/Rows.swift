import SwiftUI
import SwiftData
import UIKit

// MARK: - 공통 모양 (스페이스 그레이 · 옵시디언 느낌)

extension View {
    /// 목록 바탕을 스페이스 그레이로
    func spaceGray() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Backdrop().ignoresSafeArea())
    }
    /// 목록 한 줄 바탕
    func rowSurface() -> some View {
        self.listRowBackground(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.pill).padding(.vertical, 2))
    }
}

// MARK: - 한 줄 항목 (체크칸 없음: ← 밀면 완료, → 밀면 일정 등록)

struct ItemRow: View {
    @Environment(\.modelContext) private var ctx
    let item: Item
    var showDate = false
    /// 캘린더에서 쓸 때: 이 날짜에만 고정 (nil이면 할 일 탭의 전체 고정)
    var pinDay: Date? = nil
    var onEdit: () -> Void
    private var asker = Asker.shared
    @State private var makeEvent = false
    @State private var copied = false

    init(item: Item, showDate: Bool = false, pinDay: Date? = nil, onEdit: @escaping () -> Void) {
        self.item = item
        self.showDate = showDate
        self.pinDay = pinDay
        self.onEdit = onEdit
    }

    private var isPinned: Bool {
        if let d = pinDay { return item.isPinned(on: d) }
        return item.pinned && !item.done && item.kind == .todo
    }
    private var canPin: Bool { pinDay != nil || item.kind == .todo }

    private func togglePin() {
        if let d = pinDay { item.toggleDayPin(d) }
        else {
            item.pinned.toggle()
            item.pinnedAt = item.pinned ? .now : nil
            item.updatedAt = .now
        }
        Store.save(ctx)
    }

    private var isLate: Bool { item.kind == .todo && !item.done && Fmt.daysBetween(item.day, .now) > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(CardMarkdown.attributed(WikiText.plain(item.text)))
                    .font(.system(size: 15.5, weight: item.done ? .medium : .bold))
                    .padding(.horizontal, item.kind == .event ? 2 : 0)
                    .background(alignment: .bottom) {
                        if item.kind == .event { Theme.hl(item.uid).b.frame(height: 9).clipShape(RoundedRectangle(cornerRadius: 2)) }
                    }
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? Theme.cardSub : Theme.cardInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
                if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(CardMarkdown.attributed(item.note.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .font(.system(size: 13)).foregroundStyle(Theme.cardSub)
                        .lineLimit(4)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.14)))
                }
                linkChips
                placeChips
                PhotoStrip(ids: item.photoIDs, size: 42)
            }
            .contentShape(Rectangle())
            // 한 번 탭 = 수정, 두 번 탭 = 고정, 꾹 누르기 = 복사
            .gesture(TapGesture(count: 2).onEnded { if canPin && (pinDay != nil || !item.done) { togglePin() } }
                .exclusively(before: TapGesture().onEnded { onEdit() }))
            .onLongPressGesture(minimumDuration: 0.5) { copyText() }
            // 오른쪽 핀: 눌러서 고정 / 해제 (안 고정된 건 흐리게)
            if item.kind != .memo {
                Button {
                    item.kind = .memo
                    Store.save(ctx)
                } label: {
                    Image(systemName: "note.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cardSub.opacity(0.55))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("메모로 보내기")
            }
            if canPin && (pinDay != nil || !item.done) {
                Button(action: togglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .semibold))
                        .rotationEffect(.degrees(35))
                        .foregroundStyle(isPinned ? Theme.hi : Theme.cardSub.opacity(0.55))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPinned ? "고정 해제" : "고정")
            }
        }
        .overlay {
            if copied {
                Text("📋 복사했습니다").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 26)
        .padding(.trailing, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(note)
        .blocksTabSwipe()
        // ← 왼쪽으로 밀기: 완료 (초록) · 삭제
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.kind == .todo {
                Button { toggle() } label: {
                    Label(item.done ? "되돌리기" : "완료", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(Theme.swipeDone)
            }
            Button(role: .destructive) {
                ctx.delete(item)
                Store.save(ctx)
            } label: { Label("삭제", systemImage: "trash") }
        }
        // → 오른쪽으로 밀기: 일정 등록 (주황)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.kind == .todo {
                Button { makeEvent = true } label: { Label("일정 등록", systemImage: "calendar.badge.plus") }
                    .tint(Theme.swipeEvent)
            }
        }
        .sheet(isPresented: $makeEvent) {
            let d = max(item.day, Fmt.cal.startOfDay(for: .now))
            NewEventSheet(start: d, end: d, title: WikiText.plain(item.text))
                .presentationDetents([.medium, .large])
        }
    }

    /// 포스트잇 카드 바탕: 색 띠 + 음영
    private var noteColors: (Color, Color) {
        switch item.kind {
        case .event: let h = Theme.hl(item.uid); return (h.b, h.c)
        case .memo: return (Theme.noteMemo, Theme.memo)
        case .todo:
            if item.done { return (Theme.noteDone, Theme.line) }
            if isLate { return (Theme.noteLate, Theme.warn) }
            return (Theme.noteTodo, Theme.todo)
        }
    }

    private var note: some View {
        let (_, dot) = noteColors
        // 둥근 알약 행 + 왼쪽 색 점 (YouTube Premium 느낌)
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return shape.fill(Theme.pill)
            .overlay { if item.kind == .event { shape.fill(Theme.hl(item.uid).b) } }
            .overlay(alignment: .leading) {
                Circle().fill(dot).frame(width: 10, height: 10)
                    .background(Circle().fill(dot.opacity(0.22)).frame(width: 18, height: 18))
                    .padding(.leading, 16)
            }
            .opacity(item.done ? 0.55 : 1)
            .padding(.vertical, 2)
    }

    private func copyText() {
        var t = WikiText.plain(item.text)
        let n = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { t += "\n\n" + n }
        UIPasteboard.general.string = t
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }

    @ViewBuilder private var leading: some View {
        switch item.kind {
        case .todo:
            Group {
                if item.done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.todo)
                }
            }
            .frame(width: item.done ? 14 : 0)
        case .event:
            Text(item.isMultiDay ? "기간" : (item.time.map(Fmt.time) ?? "종일"))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.hl(item.uid).c)
                .frame(width: 40, alignment: .leading)
        case .memo:
            Circle().fill(Theme.memo).frame(width: 6, height: 6).frame(width: 14)
        }
    }

    @ViewBuilder private var placeChips: some View {
        let places = Self.places(in: item.text)
        if !places.isEmpty {
            HStack(spacing: 6) {
                ForEach(places, id: \.self) { q in
                    Button {
                        var c = URLComponents(string: "https://www.google.com/maps/search/")!
                        c.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: q)]
                        if let u = c.url { UIApplication.shared.open(u) }
                    } label: {
                        Text("📍 " + q).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(Color.green)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.16)))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    static func places(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            for part in line.split(separator: "📍").dropFirst(line.hasPrefix("📍") ? 0 : 1) {
                let q = part.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?)]"))
                if !q.isEmpty && !out.contains(q) { out.append(q) }
            }
        }
        return out
    }

    @ViewBuilder private var linkChips: some View {
        let links = WikiText.links(in: item.text)
        if !links.isEmpty {
            HStack(spacing: 6) {
                ForEach(links, id: \.self) { t in
                    Button { Router.shared.open(link: t) } label: {
                        Text("↗ " + (WikiText.date(t).map(Fmt.short) ?? t))
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(Theme.hi)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hiSoft))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var meta: some View {
        let parts = metaParts
        let marks = markParts
        if !parts.isEmpty || !marks.isEmpty {
            HStack(spacing: 7) {
                ForEach(parts, id: \.self) { p in
                    Text(p).foregroundStyle(p.hasSuffix("지남") ? Theme.warn : Theme.cardSub)
                }
                ForEach(marks, id: \.self) { m in
                    Text(m).font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.cardSub.opacity(0.35)))
                        .foregroundStyle(Theme.cardSub)
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private var metaParts: [String] {
        var p: [String] = []
        if item.isMultiDay {
            let n = Fmt.daysBetween(item.day, item.lastDay) + 1
            var s = "\(Fmt.short(item.day)) – \(Fmt.short(item.lastDay)) · \(n)일"
            if let t = item.time { s += " · \(Fmt.time(t)) 시작" }
            p.append(s)
        } else if showDate {
            p.append(Fmt.short(item.day))
        }
        if item.kind == .todo, let t = item.time { p.append(Fmt.time(t)) }
        if isLate { p.append("\(Fmt.daysBetween(item.day, .now))일 지남") }
        if item.kind == .memo { p.append(Fmt.string(item.createdAt, "a h:mm") + " 작성") }
        return p
    }

    private var markParts: [String] {
        var m: [String] = []
        if asker.busy.contains(item.uid) { m.append("GPT 답변 중…") } else if item.answer != nil { m.append("답변 있음") }
        return m
    }

    private func toggle() {
        item.done.toggle()
        item.doneAt = item.done ? .now : nil
        Store.save(ctx)
    }
}

/// 완료한 할 일 접기
struct DoneFold: View {
    let items: [Item]
    @Binding var editing: Item?
    @State private var open = false

    var body: some View {
        if !items.isEmpty {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("완료 \(items.count)")
                    Spacer()
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .rowSurface()
            if open {
                ForEach(items) { item in ItemRow(item: item) { editing = item } }
            }
        }
    }
}

// MARK: - 빠른 입력

struct Composer: View {
    @Environment(\.modelContext) private var ctx
    let day: Date
    @State private var kind: Kind = .memo
    @State private var text = ""
    @State private var hasTime = false
    @State private var time = Date()
    @FocusState private var focused: Bool

    private var placeholder: String {
        switch kind {
        case .memo: return "메모·궁금한 것을 남기세요"
        case .todo: return "할 일을 입력하세요"
        case .event: return "일정 제목 (예: 팀 회의)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("종류", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)

            HStack {
                if kind != .memo {
                    Toggle("시간", isOn: $hasTime).fixedSize().font(.subheadline)
                    if hasTime {
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                Spacer()
                Button("추가", action: add).buttonStyle(.ink)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .rowSurface()
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { focused = true; return }
        ctx.insert(Item(kind: kind, day: day, time: (kind != .memo && hasTime) ? time : nil, text: t))
        Store.save(ctx)
        text = ""
    }
}


// MARK: - 카드 안 마크다운 (굵게·기울임·코드·링크 + 제목/목록/체크 표시)

enum CardMarkdown {
    static func attributed(_ raw: String) -> AttributedString {
        var lines: [String] = []
        var inCode = false
        for l in raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if l.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { lines.append("`" + l + "`"); continue }
            var t = l
            if let r = t.range(of: #"^\s*#{1,3}\s+"#, options: .regularExpression) {
                t = "**" + t[r.upperBound...] + "**"
            } else if let r = t.range(of: #"^\s*[-*+]\s+\[( |x|X)\]\s*"#, options: .regularExpression) {
                let done = !t[r].contains("[ ]")
                t = (done ? "☑ " : "☐ ") + t[r.upperBound...]
            } else if let r = t.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                t = "• " + t[r.upperBound...]
            } else if let r = t.range(of: #"^>\s?"#, options: .regularExpression) {
                t = "▍" + t[r.upperBound...]
            }
            lines.append(t)
        }
        let src = lines.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: src, options: opts)) ?? AttributedString(src)
    }
}
