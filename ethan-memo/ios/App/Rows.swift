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
    var onEdit: () -> Void
    private var asker = Asker.shared
    @State private var makeEvent = false

    init(item: Item, showDate: Bool = false, onEdit: @escaping () -> Void) {
        self.item = item
        self.showDate = showDate
        self.onEdit = onEdit
    }

    private var isLate: Bool { item.kind == .todo && !item.done && Fmt.daysBetween(item.day, .now) > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(WikiText.plain(item.text))
                    .font(.system(size: 15, weight: item.done ? .regular : .medium))
                    .padding(.horizontal, item.kind == .event ? 2 : 0)
                    .background(alignment: .bottom) {
                        if item.kind == .event { Theme.hl(item.uid).b.frame(height: 9).clipShape(RoundedRectangle(cornerRadius: 2)) }
                    }
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
                linkChips
                PhotoStrip(ids: item.photoIDs, size: 42)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 1)
        .overlay(alignment: .leading) {
            if isLate { Rectangle().fill(Theme.warn).frame(width: 2).padding(.leading, -20) }
        }
        .rowSurface()
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

    @ViewBuilder private var leading: some View {
        switch item.kind {
        case .todo:
            Group {
                if item.done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.todo)
                } else {
                    Circle().stroke(isLate ? Theme.warn : Theme.todo, lineWidth: 2.5).frame(width: 9, height: 9)
                        .shadow(color: (isLate ? Theme.warn : Theme.todo).opacity(0.7), radius: 3)
                }
            }
            .frame(width: 14)
        case .event:
            Text(item.isMultiDay ? "기간" : (item.time.map(Fmt.time) ?? "종일"))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.hl(item.uid).t)
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
                    Text(p).foregroundStyle(p.hasSuffix("지남") ? Theme.warn : Color.secondary)
                }
                ForEach(marks, id: \.self) { m in
                    Text(m).font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                        .foregroundStyle(.secondary)
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
        if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { m.append("노트") }
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
