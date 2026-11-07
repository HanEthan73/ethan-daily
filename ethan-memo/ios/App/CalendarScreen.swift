import SwiftUI
import SwiftData
import UIKit

struct RangeDraft: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
}

struct CalendarScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Item.createdAt) private var items: [Item]
    @State private var month = Fmt.startOfMonth(.now)
    @State private var selected = Fmt.cal.startOfDay(for: .now)
    @State private var editing: Item?
    @State private var rangeDraft: RangeDraft?

    private var dayItems: [Item] { items.filter { $0.covers(selected) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 달력은 위에 고정: 드래그가 스크롤과 겹치지 않게
                MonthGrid(month: $month, selected: $selected, items: items) { s, e in
                    rangeDraft = RangeDraft(start: s, end: e)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider()

                DayList(day: selected, items: dayItems, editing: $editing)
            }
            .navigationTitle("ETHAN MEMO")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { EditSheet(item: $0) }
            .sheet(item: $rangeDraft) { d in
                NewEventSheet(start: d.start, end: d.end)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

// MARK: - 선택한 날의 목록

struct DayList: View {
    let day: Date
    let items: [Item]
    @Binding var editing: Item?

    var body: some View {
        let events = items.filter { $0.kind == .event }
            .sorted { ($0.isMultiDay ? 0 : 1, Fmt.minutes($0.time)) < ($1.isMultiDay ? 0 : 1, Fmt.minutes($1.time)) }
        let todos = items.filter { $0.kind == .todo }
            .sorted { ($0.done ? 1 : 0, Fmt.minutes($0.time)) < ($1.done ? 1 : 0, Fmt.minutes($1.time)) }
        let memos = items.filter { $0.kind == .memo }.sorted { $0.createdAt < $1.createdAt }

        List {
            Section {
                Composer(day: day)
            } header: {
                Text(Fmt.string(day, "M월 d일 EEEE"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
            if items.isEmpty {
                Section {
                    Text("이 날은 아직 비어 있습니다. 위에서 추가하거나, 달력에서 여러 날을 드래그해 일정을 만드세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !events.isEmpty {
                Section("일정 \(events.count)") {
                    ForEach(events) { item in ItemRow(item: item) { editing = item } }
                }
            }
            if !todos.isEmpty {
                Section("할 일 \(todos.filter(\.done).count)/\(todos.count)") {
                    ForEach(todos) { item in ItemRow(item: item) { editing = item } }
                }
            }
            if !memos.isEmpty {
                Section("메모 \(memos.count)") {
                    ForEach(memos) { item in ItemRow(item: item) { editing = item } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 월간 달력 (탭 = 날짜 선택, 드래그 = 기간 일정 등록)

struct MonthGrid: View {
    @Binding var month: Date
    @Binding var selected: Date
    let items: [Item]
    var onRange: (Date, Date) -> Void

    @State private var dragFrom: Int?
    @State private var dragTo: Int?
    @State private var pressTask: DispatchWorkItem?
    @State private var longPressed = false

    private let rowH: CGFloat = 70
    private let barH: CGFloat = 13
    private let maxLanes = 2

    private var firstCell: Date {
        let first = Fmt.startOfMonth(month)
        let wd = Fmt.cal.component(.weekday, from: first) // 1 = 일요일
        return Fmt.addDays(first, -(wd - 1))
    }
    private var weeks: Int {
        let first = Fmt.startOfMonth(month)
        let wd = Fmt.cal.component(.weekday, from: first) - 1
        let n = Fmt.cal.range(of: .day, in: .month, for: first)?.count ?? 30
        return Int(ceil(Double(wd + n) / 7.0))
    }
    private var days: [Date] { (0..<(weeks * 7)).map { Fmt.addDays(firstCell, $0) } }

    /// 하루짜리 항목 → 점
    private var dots: [Date: Set<Kind>] {
        var m: [Date: Set<Kind>] = [:]
        for i in items where i.kind != .event && !(i.kind == .todo && i.done) {
            m[i.day, default: []].insert(i.kind)
        }
        return m
    }

    struct Seg: Identifiable {
        let id: String
        let title: String
        let row: Int, start: Int, end: Int, lane: Int
        let openLeft: Bool, openRight: Bool
    }

    /// 여러 날 일정 → 주(週) 단위로 잘린 이어진 막대
    private var bars: [Seg] {
        let n = weeks * 7
        let first = firstCell
        let multi = items.filter { $0.kind == .event }.sorted {
            ($0.day, -Fmt.daysBetween($0.day, $0.lastDay), Fmt.minutes($0.time), $0.createdAt) < ($1.day, -Fmt.daysBetween($1.day, $1.lastDay), Fmt.minutes($1.time), $1.createdAt)
        }
        var laneEnds: [Int] = []
        var out: [Seg] = []
        for ev in multi {
            let s = Fmt.daysBetween(first, ev.day)
            let e = Fmt.daysBetween(first, ev.lastDay)
            if e < 0 || s >= n { continue }
            let cs = max(0, s), ce = min(n - 1, e)
            var lane = laneEnds.firstIndex(where: { $0 < cs }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(ce) } else { laneEnds[lane] = ce }
            if lane >= maxLanes { lane = -1 }
            if lane < 0 { continue }
            var i = cs
            while i <= ce {
                let row = i / 7
                let rowEnd = min(ce, row * 7 + 6)
                out.append(Seg(id: "\(ev.uid)-\(row)", title: ev.text, row: row,
                               start: i % 7, end: rowEnd % 7, lane: lane,
                               openLeft: i > s, openRight: rowEnd < e))
                i = rowEnd + 1
            }
        }
        return out
    }

    /// 드래그 중인 범위 → 주 단위 하이라이트(이어진 모양)
    private var dragSegs: [(row: Int, start: Int, end: Int)] {
        guard let a = dragFrom, let b = dragTo, a != b else { return [] }
        let lo = min(a, b), hi = max(a, b)
        var out: [(row: Int, start: Int, end: Int)] = []
        var i = lo
        while i <= hi {
            let row = i / 7
            let rowEnd = min(hi, row * 7 + 6)
            out.append((row: row, start: i % 7, end: rowEnd % 7))
            i = rowEnd + 1
        }
        return out
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(Fmt.string(month, "yyyy년 M월"))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer()
                Button("오늘") {
                    let t = Fmt.cal.startOfDay(for: .now)
                    selected = t
                    month = Fmt.startOfMonth(t)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
            }
            .padding(.top, 6)

            HStack(spacing: 0) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { i, s in
                    Text(s)
                        .font(.caption)
                        .foregroundStyle(i == 0 ? Color.red : i == 6 ? Color.blue : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            GeometryReader { geo in
                let w = geo.size.width / 7
                ZStack(alignment: .topLeading) {
                    // 1) 드래그 범위
                    ForEach(Array(dragSegs.enumerated()), id: \.offset) { _, seg in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: CGFloat(seg.end - seg.start + 1) * w - 2, height: rowH - 4)
                            .offset(x: CGFloat(seg.start) * w + 1, y: CGFloat(seg.row) * rowH + 2)
                    }
                    // 2) 날짜 칸
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        DayCell(date: d,
                                inMonth: Fmt.cal.isDate(d, equalTo: month, toGranularity: .month),
                                isToday: Fmt.cal.isDateInToday(d),
                                isSelected: Fmt.cal.isDate(d, inSameDayAs: selected),
                                kinds: dots[d] ?? [],
                                column: i % 7)
                            .frame(width: w, height: rowH)
                            .offset(x: CGFloat(i % 7) * w, y: CGFloat(i / 7) * rowH)
                    }
                    // 3) 여러 날 일정 막대
                    ForEach(bars) { b in
                        Text(b.title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(width: CGFloat(b.end - b.start + 1) * w - (b.openLeft ? 0 : 2) - (b.openRight ? 0 : 2),
                                   height: barH, alignment: .leading)
                            .foregroundStyle(.white)
                            .background(
                                UnevenRoundedRectangle(topLeadingRadius: b.openLeft ? 0 : 4,
                                                       bottomLeadingRadius: b.openLeft ? 0 : 4,
                                                       bottomTrailingRadius: b.openRight ? 0 : 4,
                                                       topTrailingRadius: b.openRight ? 0 : 4)
                                    .fill(Color.blue)
                            )
                            .offset(x: CGFloat(b.start) * w + (b.openLeft ? 0 : 2),
                                    y: CGFloat(b.row) * rowH + 33 + CGFloat(b.lane) * (barH + 1))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if longPressed { return }
                            let idx = index(at: v.location, w: w)
                            if dragFrom == nil {
                                let start = index(at: v.startLocation, w: w)
                                dragFrom = start
                                // 꾹 누르기(0.45초) → 그날 하루 일정 등록
                                let task = DispatchWorkItem {
                                    guard dragFrom == start, dragTo == nil || dragTo == start else { return }
                                    longPressed = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    let d = days[start]
                                    selected = d
                                    onRange(d, d)
                                }
                                pressTask = task
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: task)
                            }
                            if dragTo != idx {
                                dragTo = idx
                                if dragFrom != idx {
                                    pressTask?.cancel()
                                    UISelectionFeedbackGenerator().selectionChanged()
                                }
                            }
                        }
                        .onEnded { v in
                            pressTask?.cancel()
                            pressTask = nil
                            if longPressed {
                                longPressed = false
                                dragFrom = nil
                                dragTo = nil
                                return
                            }
                            let a = dragFrom ?? index(at: v.startLocation, w: w)
                            let b = index(at: v.location, w: w)
                            dragFrom = nil
                            dragTo = nil
                            let all = days
                            if a == b {
                                let d = all[a]
                                selected = d
                                if !Fmt.cal.isDate(d, equalTo: month, toGranularity: .month) { month = Fmt.startOfMonth(d) }
                            } else {
                                let s = all[min(a, b)], e = all[max(a, b)]
                                selected = s
                                onRange(s, e)
                            }
                        }
                )
            }
            .frame(height: CGFloat(weeks) * rowH)

            HStack(spacing: 14) {
                legend(.event, "일정")
                legend(.todo, "할 일")
                legend(.memo, "메모")
                Spacer()
                Text("꾹 누르기·드래그로 일정").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ k: Kind, _ s: String) -> some View {
        HStack(spacing: 4) { Circle().fill(k.color).frame(width: 6, height: 6); Text(s) }
    }

    private func index(at p: CGPoint, w: CGFloat) -> Int {
        let col = min(6, max(0, Int(p.x / w)))
        let row = min(weeks - 1, max(0, Int(p.y / rowH)))
        return row * 7 + col
    }

    private func shift(_ n: Int) {
        month = Fmt.cal.date(byAdding: .month, value: n, to: month) ?? month
    }
}

struct DayCell: View {
    let date: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let kinds: Set<Kind>
    let column: Int

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Fmt.cal.component(.day, from: date))")
                .font(.callout.monospacedDigit())
                .fontWeight(isToday || isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.white : column == 0 ? Color.red : column == 6 ? Color.blue : Color.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isSelected ? Color.accentColor : Color.clear))
                .overlay(Circle().stroke(isToday && !isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                .padding(.top, 2)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach([Kind.event, .todo, .memo].filter { kinds.contains($0) }) { k in
                    Circle().fill(k.color).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
            .padding(.bottom, 3)
        }
        .opacity(inMonth ? 1 : 0.35)
    }
}
