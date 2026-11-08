import SwiftUI
import SwiftData
import UIKit

// MARK: - 한 줄 항목

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(WikiText.plain(item.text))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
                linkChips
                answerBlock
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 2)
        // ← 왼쪽으로 밀기: 일정 등록 (할 일) · 삭제
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.kind == .todo {
                Button { makeEvent = true } label: { Label("일정 등록", systemImage: "calendar.badge.plus") }
                    .tint(Theme.swipeEvent)
            }
            Button(role: .destructive) {
                ctx.delete(item)
                Store.save(ctx)
            } label: { Label("삭제", systemImage: "trash") }
        }
        // → 오른쪽으로 밀기: 완료
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.kind == .todo {
                Button { toggle() } label: {
                    Label(item.done ? "되돌리기" : "완료", systemImage: item.done ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(Theme.swipeDone)
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
            Button { toggle() } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Theme.todo : Color.secondary)
            }
            .buttonStyle(.borderless)
        case .event:
            Group {
                if item.isMultiDay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 3)
                } else {
                    Text(item.time.map(Fmt.time) ?? "종일")
                        .font(.subheadline.monospacedDigit())
                }
            }
            .foregroundStyle(Theme.event)
            .frame(width: 44, alignment: .leading)
        case .memo:
            Circle().fill(Theme.memo).frame(width: 7, height: 7).padding(.top, 7)
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
                            .foregroundStyle(Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var meta: some View {
        let parts = metaParts
        if !parts.isEmpty {
            HStack(spacing: 8) {
                ForEach(parts, id: \.self) { Text($0) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        if item.kind == .todo, !item.done {
            let late = Fmt.daysBetween(item.day, .now)
            if late > 0 { p.append("\(late)일 지남") }
        }
        if item.kind == .memo { p.append(Fmt.string(item.createdAt, "a h:mm") + " 작성") }
        return p
    }

    /// 목록에서는 표시만 (묻기·답변은 항목을 눌러 들어간 화면에서)
    @ViewBuilder private var answerBlock: some View {
        if asker.busy.contains(item.uid) {
            Text("Claude 답변 중…").font(.caption2).foregroundStyle(.secondary)
        } else if item.answer != nil {
            Text("답변 있음")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separator)))
        }
    }

    private func toggle() {
        item.done.toggle()
        item.doneAt = item.done ? .now : nil
        Store.save(ctx)
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
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { add(ask: false) }

            HStack {
                if kind != .memo {
                    Toggle("시간", isOn: $hasTime).fixedSize()
                    if hasTime {
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                Spacer()
                Button("추가") { add(ask: false) }
                    .buttonStyle(.ink)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func add(ask: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { focused = true; return }
        let item = Item(kind: kind, day: day, time: (kind != .memo && hasTime) ? time : nil, text: t)
        ctx.insert(item)
        Store.save(ctx)
        text = ""
        if ask { Asker.shared.ask(item, ctx: ctx) }
    }
}
