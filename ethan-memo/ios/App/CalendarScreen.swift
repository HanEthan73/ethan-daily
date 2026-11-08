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
    private var router = Router.shared

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
                .background(Theme.bg)

                Rectangle().fill(Theme.line).frame(height: 0.5)

                DayList(day: selected, items: dayItems, editing: $editing)
            }
            .navigationTitle("ETHAN MEMO")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { EditSheet(item: $0) }
            .onAppear(perform: applyJump)
            .onChange(of: router.jumpDate) { _, _ in applyJump() }
            .sheet(item: $rangeDraft) { d in
                NewEventSheet(start: d.start, end: d.end)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

extension CalendarScreen {
    func applyJump() {
        guard let d = router.jumpDate else { return }
        router.jumpDate = nil
        selected = Fmt.cal.startOfDay(for: d)
        month = Fmt.startOfMonth(d)
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
        let open = todos.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt }
        let done = todos.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        let memos = items.filter { $0.kind == .memo }.sorted { $0.createdAt > $1.createdAt }

        List {
            Section {
                Composer(day: day)
            } header: {
                HStack(spacing: 8) {
                    Text(Fmt.string(day, "M월 d일 EEEE"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    if let h = Holidays.shared.name(day) {
                        Text(h).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sun)
                    }
                }
                .textCase(nil)
            }
            if items.isEmpty {
                Section {
                    Text("이 날은 비어 있습니다. 위에서 추가하거나, 달력을 꾹 누른 채 끌어 일정을 만드세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .rowSurface()
                }
            }
            if !events.isEmpty {
                Section(header: head("일정", "\(events.count)", Theme.hi)) {
                    ForEach(events) { item in ItemRow(item: item) { editing = item } }
                }
            }
            if !todos.isEmpty {
                Section(header: head("할 일", "\(done.count)/\(todos.count)", Theme.todo)) {
                    ForEach(open) { item in ItemRow(item: item) { editing = item } }
                    DoneFold(items: done, editing: $editing)
                }
            }
            if !memos.isEmpty {
                Section(header: head("메모", "\(memos.count)", Theme.memo)) {
                    ForEach(memos) { item in ItemRow(item: item) { editing = item } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .spaceGray()
    }

    private func head(_ t: String, _ n: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 12, weight: .semibold))
            Text(n).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }
}

// MARK: - 월간 달력
// 탭 = 날짜 선택 · 꾹 누르기(0.38초) = 그날 일정 · 꾹 누른 채 끌기 = 기간 일정 · 좌우로 밀기 = 달 바꾸기

struct MonthGrid: View {
    @Binding var month: Date
    @Binding var selected: Date
    let items: [Item]
    var onRange: (Date, Date) -> Void

    @State private var dragFrom: Int?
    @State private var dragTo: Int?
    @State private var selecting = false
    @State private var moved = false
    @State private var began = false
    @State private var pressTask: DispatchWorkItem?

    private let rowH: CGFloat = 76
    private let barTop: CGFloat = 41
    private let barH: CGFloat = 15
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

    /// 할 일·메모 → 점
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
        let key: String
        let row: Int, start: Int, end: Int, lane: Int
        let openLeft: Bool, openRight: Bool
    }

    /// 일정 → 주 단위로 잘린 이어진 막대 (하루 일정도 막대)
    private var bars: [Seg] {
        let n = weeks * 7
        let first = firstCell
        let evs = items.filter { $0.kind == .event }.sorted {
            ($0.day, -Fmt.daysBetween($0.day, $0.lastDay), Fmt.minutes($0.time), $0.createdAt) < ($1.day, -Fmt.daysBetween($1.day, $1.lastDay), Fmt.minutes($1.time), $1.createdAt)
        }
        var laneEnds: [Int] = []
        var out: [Seg] = []
        for ev in evs {
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
                out.append(Seg(id: "\(ev.uid)-\(row)", title: ev.text, key: ev.uid, row: row,
                               start: i % 7, end: rowEnd % 7, lane: lane,
                               openLeft: i > s, openRight: rowEnd < e))
                i = rowEnd + 1
            }
        }
        return out
    }

    /// 선택 중인 범위 → 주 단위 하이라이트
    private var dragSegs: [(row: Int, start: Int, end: Int)] {
        guard selecting, let a = dragFrom, let b = dragTo else { return [] }
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
                Text(Fmt.string(month, "yyyy. M"))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                Text("월").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("오늘") {
                    let t = Fmt.cal.startOfDay(for: .now)
                    selected = t
                    withAnimation(.snappy) { month = Fmt.startOfMonth(t) }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(Theme.hi)
                .background(Capsule().fill(Theme.hiSoft))
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
            }
            .tint(.secondary)
            .padding(.top, 6)

            HStack(spacing: 0) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { i, s in
                    Text(s)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(i == 0 ? Theme.sun : Color.secondary)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }

            GeometryReader { geo in
                let w = geo.size.width / 7
                ZStack(alignment: .topLeading) {
                    // 1) 선택 범위
                    ForEach(Array(dragSegs.enumerated()), id: \.offset) { _, seg in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.hiSoft)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hi.opacity(0.6), lineWidth: 1))
                            .frame(width: CGFloat(seg.end - seg.start + 1) * w - 2, height: rowH - 4)
                            .offset(x: CGFloat(seg.start) * w + 1, y: CGFloat(seg.row) * rowH + 2)
                    }
                    // 2) 날짜 칸
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        DayCell(date: d,
                                inMonth: Fmt.cal.isDate(d, equalTo: month, toGranularity: .month),
                                isToday: Fmt.cal.isDateInToday(d),
                                isSelected: Fmt.cal.isDate(d, inSameDayAs: selected),
                                holiday: Holidays.shared.short(d),
                                kinds: dots[d] ?? [],
                                column: i % 7)
                            .frame(width: w, height: rowH)
                            .offset(x: CGFloat(i % 7) * w, y: CGFloat(i / 7) * rowH)
                    }
                    // 3) 일정 막대
                    ForEach(bars) { b in
                        let c = Theme.hl(b.key)
                        Text(b.openLeft && b.start != 0 ? " " : b.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .padding(.leading, 5).padding(.trailing, 3)
                            .frame(width: CGFloat(b.end - b.start + 1) * w - (b.openLeft ? 0 : 2) - (b.openRight ? 0 : 2),
                                   height: barH, alignment: .leading)
                            .foregroundStyle(c.t)
                            .background(
                                UnevenRoundedRectangle(topLeadingRadius: b.openLeft ? 0 : 4,
                                                       bottomLeadingRadius: b.openLeft ? 0 : 4,
                                                       bottomTrailingRadius: b.openRight ? 0 : 4,
                                                       topTrailingRadius: b.openRight ? 0 : 4)
                                    .fill(c.b)
                            )
                            .overlay(alignment: .leading) {
                                if !b.openLeft { Rectangle().fill(c.c).frame(width: 2.5) }
                            }
                            .offset(x: CGFloat(b.start) * w + (b.openLeft ? 0 : 2),
                                    y: CGFloat(b.row) * rowH + barTop + CGFloat(b.lane) * (barH + 2))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in changed(v, w: w) }
                        .onEnded { v in ended(v, w: w) }
                )
            }
            .frame(height: CGFloat(weeks) * rowH)
            .id(month)
            .transition(.opacity)

            HStack(spacing: 12) {
                legend(Theme.event, "일정")
                legend(Theme.todo, "할 일")
                legend(Theme.memo, "메모")
                Spacer()
                Text("꾹 눌러 일정 · 끌어서 기간 · 좌우로 달").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 손동작

    private func changed(_ v: DragGesture.Value, w: CGFloat) {
        if !began {
            began = true
            moved = false
            let start = index(at: v.startLocation, w: w)
            let task = DispatchWorkItem {
                guard began, !moved else { return }
                selecting = true
                dragFrom = start
                dragTo = start
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            pressTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: task)
        }
        if selecting {
            let idx = index(at: v.location, w: w)
            if dragTo != idx {
                dragTo = idx
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } else if hypot(v.translation.width, v.translation.height) > 10 {
            moved = true
            pressTask?.cancel()
        }
    }

    private func ended(_ v: DragGesture.Value, w: CGFloat) {
        pressTask?.cancel()
        pressTask = nil
        defer { began = false; moved = false; selecting = false; dragFrom = nil; dragTo = nil }
        let all = days
        if selecting, let a = dragFrom, let b = dragTo {
            let s = all[min(a, b)], e = all[max(a, b)]
            selected = s
            onRange(s, e)
            return
        }
        if moved {
            let dx = v.translation.width, dy = v.translation.height
            if abs(dx) > 45 && abs(dx) > abs(dy) * 1.2 { shift(dx < 0 ? 1 : -1) }
            return
        }
        let d = all[index(at: v.location, w: w)]
        selected = d
        if !Fmt.cal.isDate(d, equalTo: month, toGranularity: .month) {
            withAnimation(.snappy) { month = Fmt.startOfMonth(d) }
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(s) }
    }

    private func index(at p: CGPoint, w: CGFloat) -> Int {
        let col = min(6, max(0, Int(p.x / w)))
        let row = min(weeks - 1, max(0, Int(p.y / rowH)))
        return row * 7 + col
    }

    private func shift(_ n: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy) {
            month = Fmt.cal.date(byAdding: .month, value: n, to: month) ?? month
        }
    }
}

struct DayCell: View {
    let date: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let holiday: String?
    let kinds: Set<Kind>
    let column: Int

    private var red: Bool { column == 0 || holiday != nil }

    var body: some View {
        VStack(spacing: 1) {
            Text("\(Fmt.cal.component(.day, from: date))")
                .font(.system(size: 14, weight: isToday || isSelected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : isSelected ? Theme.bg : red ? Theme.sun : Color.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isToday ? Theme.today : isSelected ? Color.primary : Color.clear))
                .overlay(Circle().stroke(isToday && isSelected ? Theme.today : Color.clear, lineWidth: 1.5).padding(-3))
                .padding(.top, 2)
            Text(holiday ?? " ")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Theme.sun)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 10)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach([Kind.todo, .memo].filter { kinds.contains($0) }) { k in
                    Circle().fill(k.color).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .opacity(inMonth ? 1 : 0.32)
    }
}
