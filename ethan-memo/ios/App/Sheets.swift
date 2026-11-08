import SwiftUI
import SwiftData

// MARK: - 달력 드래그로 연 기간 일정 등록

struct NewEventSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start: Date
    @State private var end: Date
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @FocusState private var focused: Bool

    init(start: Date, end: Date, title: String = "") {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _title = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("일정 제목 (예: 부산 출장)", text: $title)
                        .focused($focused)
                }
                Section {
                    DatePicker("시작", selection: $start, displayedComponents: .date)
                    DatePicker("종료", selection: $end, in: start..., displayedComponents: .date)
                    Toggle("시작 시간 지정", isOn: $hasTime)
                    if hasTime {
                        DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("\(Fmt.short(start)) – \(Fmt.short(end)) · \(Fmt.daysBetween(start, end) + 1)일")
                }
            }
            .navigationTitle("일정 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
            .onChange(of: start) { _, s in if end < s { end = s } }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let item = Item(kind: .event, day: start, endDay: end, time: hasTime ? time : nil, text: t)
        ctx.insert(item)
        Store.save(ctx)
        dismiss()
    }
}

// MARK: - 수정

struct EditSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var kind: Kind
    @State private var text: String
    @State private var day: Date
    @State private var end: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var done: Bool
    @State private var confirmDelete = false

    init(item: Item) {
        self.item = item
        _kind = State(initialValue: item.kind)
        _text = State(initialValue: item.text)
        _day = State(initialValue: item.day)
        _end = State(initialValue: item.lastDay)
        _hasTime = State(initialValue: item.time != nil)
        _time = State(initialValue: item.time ?? .now)
        _done = State(initialValue: item.done)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("종류", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("내용", text: $text, axis: .vertical)
                        .lineLimit(2...10)
                }
                Section {
                    DatePicker(kind == .event ? "시작" : "날짜", selection: $day, displayedComponents: .date)
                    if kind == .event {
                        DatePicker("종료", selection: $end, in: day..., displayedComponents: .date)
                    }
                    if kind != .memo {
                        Toggle("시간 지정", isOn: $hasTime)
                        if hasTime {
                            DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
                        }
                    }
                    if kind == .todo {
                        Toggle("완료", isOn: $done)
                    }
                }
                Section {
                    let asking = Asker.shared.busy.contains(item.uid)
                    Button {
                        save(close: false)
                        Asker.shared.ask(item, ctx: ctx)
                    } label: {
                        if asking { HStack(spacing: 8) { ProgressView(); Text("Claude가 답하는 중…") } }
                        else { Label(item.answer == nil ? "Claude에게 묻기" : "다시 묻기", systemImage: "sparkle") }
                    }
                    .disabled(asking)
                    ShareLink(item: text) { Label("Claude 앱으로 보내기", systemImage: "square.and.arrow.up") }
                    if let a = item.answer {
                        Text(a).font(.subheadline).textSelection(.enabled)
                    }
                } header: { Text("Claude") }
                Section {
                    Button("삭제", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("\(kind.label) 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save(close: true) } }
            }
            .onChange(of: day) { _, d in if end < d { end = d } }
            .confirmationDialog("이 기록을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    ctx.delete(item)
                    Store.save(ctx)
                    dismiss()
                }
            }
        }
    }

    private func save(close: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        item.kind = kind
        item.text = t
        item.day = Fmt.cal.startOfDay(for: day)
        let e = Fmt.cal.startOfDay(for: end)
        item.endDay = (kind == .event && e > item.day) ? e : nil
        item.time = (kind != .memo && hasTime) ? time : nil
        item.done = kind == .todo ? done : false
        item.doneAt = item.done ? (item.doneAt ?? .now) : nil
        Store.save(ctx)
        if close { dismiss() }
    }
}
