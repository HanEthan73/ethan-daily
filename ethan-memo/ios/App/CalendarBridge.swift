import SwiftUI
import SwiftData
import EventKit
import Observation
import UIKit

// MARK: - 구글 캘린더 연동 (아이폰 ‘캘린더’에 추가한 구글 계정을 EventKit으로 읽고 씀)
// 설정 앱 → 캘린더 → 계정 → Google 추가 → ‘캘린더’ 켜기 만 하면 별도 키·로그인 없이 동작

@MainActor
@Observable
final class CalendarBridge {
    static let shared = CalendarBridge()

    var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    /// 구글·아이폰 캘린더 일정 (앱 저장소에는 넣지 않는 표시용 Item)
    var ext: [Item] = []
    var lastSync: Date?

    @ObservationIgnored let store = EKEventStore()
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let showKey = "gcalShow", pushKey = "gcalPush", targetKey = "gcalTarget"
    var show: Bool { UserDefaults.standard.bool(forKey: Self.showKey) }
    var push: Bool { UserDefaults.standard.object(forKey: Self.pushKey) as? Bool ?? true }

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        })
    }

    func requestAccess() async -> Bool {
        do { authorized = try await store.requestFullAccessToEvents() } catch { authorized = false }
        if authorized { store.refreshSourcesIfNecessary() }
        return authorized
    }

    /// 쓸 수 있는 캘린더 (구글 계정 캘린더가 먼저)
    var writableCalendars: [EKCalendar] {
        guard authorized else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { ($0.source.title.localizedCaseInsensitiveContains("google") ? 0 : 1, $0.title) < ($1.source.title.localizedCaseInsensitiveContains("google") ? 0 : 1, $1.title) }
    }
    var target: EKCalendar? {
        guard authorized else { return nil }
        if let id = UserDefaults.standard.string(forKey: Self.targetKey), let c = store.calendar(withIdentifier: id) { return c }
        return writableCalendars.first { $0.source.title.localizedCaseInsensitiveContains("google") || $0.source.sourceType == .calDAV }
            ?? store.defaultCalendarForNewEvents
    }
    var googleAccountFound: Bool {
        authorized && store.sources.contains { $0.title.localizedCaseInsensitiveContains("google") || $0.title.localizedCaseInsensitiveContains("gmail") }
    }

    private static func isOurs(_ e: EKEvent) -> Bool { e.url?.scheme == "ethanmemo" }

    // MARK: 읽기
    func reload() {
        guard authorized, show else { ext = []; return }
        let cal = Fmt.cal
        let start = Fmt.addDays(cal.startOfDay(for: .now), -120), end = Fmt.addDays(cal.startOfDay(for: .now), 400)
        let cals = store.calendars(for: .event).filter {
            $0.type != .birthday && !$0.title.contains("휴일") && !$0.title.localizedCaseInsensitiveContains("holiday")
        }
        guard !cals.isEmpty else { ext = []; return }
        let evs = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals))
        ext = evs.filter { !Self.isOurs($0) }.compactMap { e in
            guard let s = e.startDate, let en = e.endDate else { return nil }
            let day = cal.startOfDay(for: s)
            let last = cal.startOfDay(for: en.addingTimeInterval(-1))
            let it = Item(kind: .event, day: day, endDay: last > day ? last : nil, time: e.isAllDay ? nil : s, text: e.title ?? "(제목 없음)")
            it.uid = "ek:\(e.calendarItemIdentifier)@\(Int(s.timeIntervalSince1970))"
            it.extID = e.eventIdentifier
            it.extCal = e.calendar.title
            if let loc = e.location, !loc.isEmpty { it.note = "📍" + loc }
            return it
        }
        lastSync = .now
    }

    // MARK: 쓰기 (앱 일정 → 고른 캘린더). 저장할 때마다 1초 뒤 한 번에 맞춤
    func schedulePush(_ ctx: ModelContext) {
        guard authorized, show, push else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self.pushAll(ctx)
        }
    }

    func pushAll(_ ctx: ModelContext) {
        guard authorized, show, push, let cal = target else { return }
        let now = Date()
        let all = (try? ctx.fetch(FetchDescriptor<Item>())) ?? []
        let events = all.filter { $0.kind == .event }
        let allUIDs = Set(all.map(\.uid))
        let eventUIDs = Set(events.map(\.uid))
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-400 * 86400), end: now.addingTimeInterval(800 * 86400), calendars: [cal])
        var mine: [String: EKEvent] = [:]
        for e in store.events(matching: pred) where Self.isOurs(e) { mine[e.url!.lastPathComponent] = e }
        let recent = Fmt.addDays(Fmt.cal.startOfDay(for: now), -30)
        var changed = false
        for it in events {
            let ev: EKEvent
            if let e = mine[it.uid] { ev = e }
            else {
                guard it.lastDay >= recent else { continue }
                ev = EKEvent(eventStore: store)
                ev.calendar = cal
                ev.url = URL(string: "ethanmemo://item/\(it.uid)")
            }
            let title = WikiText.plain(it.text).components(separatedBy: "\n").first ?? it.text
            let allDay = it.time == nil
            let start: Date, end: Date
            if let t = it.time {
                let c = Fmt.cal.dateComponents([.hour, .minute], from: t)
                start = Fmt.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: it.day) ?? it.day
                let endBase = Fmt.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: it.lastDay) ?? start
                end = endBase > start ? endBase : start.addingTimeInterval(3600)
            } else {
                start = it.day
                end = Fmt.addDays(it.lastDay, 1)
            }
            let notes = it.note.isEmpty ? "— ETHAN MEMO" : it.note + "\n\n— ETHAN MEMO"
            if ev.title != title || ev.isAllDay != allDay || ev.startDate != start || ev.endDate != end || (ev.notes ?? "") != notes {
                ev.title = title; ev.isAllDay = allDay; ev.startDate = start; ev.endDate = end; ev.notes = notes
                if (try? store.save(ev, span: .thisEvent, commit: false)) != nil { changed = true }
            }
        }
        // 앱에서 지웠거나 일정이 아니게 된 것 → 캘린더에서도 지움
        let dead = Dead.load()
        for (uid, e) in mine where !eventUIDs.contains(uid) && (dead[uid] != nil || allUIDs.contains(uid)) {
            if (try? store.remove(e, span: .thisEvent, commit: false)) != nil { changed = true }
        }
        if changed { try? store.commit() }
    }

    /// 구글·아이폰 캘린더 일정 열기
    static func open(_ item: Item) {
        let at = item.time ?? item.day
        if let u = URL(string: "calshow:\(Int(at.timeIntervalSinceReferenceDate))") { UIApplication.shared.open(u) }
    }
}

/// 구글·아이폰 캘린더에서 온 일정 한 줄 (읽기 전용 · 누르면 캘린더 앱)
struct ExtRow: View {
    let item: Item
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.endDay != nil ? "기간" : (item.time.map(Fmt.time) ?? "종일"))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.cardSub)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.system(size: 15.5, weight: .bold)).foregroundStyle(Theme.cardInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text("G · " + (item.extCal ?? "캘린더"))
                        .font(.system(size: 11.5, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .foregroundStyle(Color(red: 0.54, green: 0.71, blue: 0.97))
                        .background(Capsule().fill(Color.blue.opacity(0.2)))
                    if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(Theme.cardSub).lineLimit(1) }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { CalendarBridge.open(item) }
        .padding(.vertical, 6).padding(.leading, 14).padding(.trailing, 6)
        .listRowSeparator(.hidden)
        .rowSurface()
        .blocksTabSwipe()
    }
}
