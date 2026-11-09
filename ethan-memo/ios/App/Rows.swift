import SwiftUI
import SwiftData
import UIKit

// MARK: - 공통 모양 (스페이스 그레이 · 옵시디언 느낌)

extension View {
    /// 목록 바탕을 스페이스 그레이로
    func spaceGray() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
    /// 목록 한 줄 바탕
    func rowSurface() -> some View { self.listRowBackground(Theme.surface) }
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

    private var isLate: Bool { item.kind == .todo && !item.done && Fmt.daysBetween(item.day, .now) > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(CardMarkdown.attributed(WikiText.plain(item.text)))
                    .font(.system(size: 14.5, weight: item.done ? .medium : .bold))
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
                PhotoStrip(ids: item.photoIDs, size: 42)
            }
            .contentShape(Rectangle())
            // 한 번 탭 = 수정, 두 번 탭 = 복사
            .gesture(TapGesture(count: 2).onEnded { copyText() }
                .exclusively(before: TapGesture().onEnded { onEdit() }))
        }
        .padding(.trailing, isPinned ? 18 : 0)
        .overlay {
            if copied {
                Text("📋 복사했습니다").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(note)
        .overlay(alignment: .leading) {
            if isLate { Rectangle().fill(Theme.warn).frame(width: 2).padding(.leading, -20) }
        }
        .contextMenu {
            if canPin {
                Button {
                    if let d = pinDay { item.toggleDayPin(d) }
                    else {
                        item.pinned.toggle()
                        item.pinnedAt = item.pinned ? .now : nil
                        item.updatedAt = .now
                    }
                    Store.save(ctx)
                } label: {
                    Label(isPinned ? "고정 해제" : (pinDay != nil ? "이 날짜 맨 위에 고정" : "맨 위에 고정"),
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
            }
            Button(action: onEdit) { Label("수정", systemImage: "pencil") }
        }
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
        let (_, strip) = noteColors
        // 캘린더 막대와 같은 모양: 둥근 모서리를 따라 휘는 왼쪽 색 띠
        let shape = RoundedRectangle(cornerRadius: 7)
        let pinned = isPinned
        return shape.fill(strip)
            .overlay {
                shape.fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom], startPoint: .top, endPoint: .bottom))
                    .padding(.leading, 3.5)
            }
            .overlay(shape.strokeBorder(Theme.cardLip, lineWidth: 0.5))
            .overlay(shape.strokeBorder(Theme.cardHi, lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .overlay(alignment: .topTrailing) {
                if pinned {
                    // 작고 조용한 핀 아이콘만
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10.5))
                        .rotationEffect(.degrees(35))
                        .foregroundStyle(Theme.hi.opacity(0.85))
                        .padding(.top, 7).padding(.trailing, 9)
                }
            }
            .shadow(color: Theme.cardShadow, radius: 3.5, y: 2.5)
            .opacity(item.done ? 0.8 : 1)
            .padding(.top, 2).padding(.bottom, 3)
            .padding(.horizontal, 2)
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
        if asker.busy.contains(item.uid) { m.append("Claude 답변 중…") } else if item.answer != nil { m.append("답변 있음") }
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
