import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct TodoSnap: Identifiable {
    let id: String
    let text: String
    let day: Date
}

struct TodoEntry: TimelineEntry {
    let date: Date
    let todos: [TodoSnap]
    let total: Int
    let todayCount: Int
    let lateCount: Int
}

struct TodoProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoEntry {
        TodoEntry(date: .now,
                  todos: [TodoSnap(id: "1", text: "장보기 목록 정리", day: .now),
                          TodoSnap(id: "2", text: "택배 반품 접수", day: .now)],
                  total: 2, todayCount: 2, lateCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        // 자정에 '오늘/지난' 구분이 바뀌므로 다음 자정에 갱신. 앱에서 변경하면 즉시 갱신됨.
        let midnight = Fmt.cal.startOfDay(for: Fmt.addDays(.now, 1))
        completion(Timeline(entries: [load()], policy: .after(midnight)))
    }

    private func load() -> TodoEntry {
        let ctx = ModelContext(Store.container)
        let fd = FetchDescriptor<Item>(predicate: #Predicate { $0.kindRaw == "todo" && $0.done == false },
                                       sortBy: [SortDescriptor(\Item.day), SortDescriptor(\Item.createdAt)])
        let items = (try? ctx.fetch(fd)) ?? []
        let today = Fmt.cal.startOfDay(for: .now)
        return TodoEntry(date: .now,
                         todos: items.map { TodoSnap(id: $0.uid, text: $0.text, day: $0.day) },
                         total: items.count,
                         todayCount: items.filter { $0.day == today }.count,
                         lateCount: items.filter { $0.day < today }.count)
    }
}

struct TodoWidgetView: View {
    let entry: TodoEntry
    @Environment(\.widgetFamily) private var family

    private var rows: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        default: return 8
        }
    }

    struct Line: Identifiable {
        enum K { case header(Date, Int), todo(TodoSnap) }
        let id: String
        let kind: K
        var first = false
    }

    /// 날짜별로 끊은 줄 목록(최신 날짜가 위), 크기에 맞게 자름
    private var lines: [Line] {
        let maxLines: Int
        switch family {
        case .systemSmall: maxLines = 4
        case .systemMedium: maxLines = 4
        default: maxLines = 12
        }
        let groups = Dictionary(grouping: entry.todos) { $0.day }
        var out: [Line] = []
        for d in groups.keys.sorted(by: >) {
            if out.count >= maxLines - 1 { break }
            let list = groups[d] ?? []
            out.append(Line(id: "h\(d.timeIntervalSince1970)", kind: .header(d, list.count), first: out.isEmpty))
            for t in list {
                if out.count >= maxLines { break }
                out.append(Line(id: t.id, kind: .todo(t)))
            }
        }
        return out
    }

    private func relative(_ d: Date) -> String {
        let n = Fmt.daysBetween(.now, d)
        switch n {
        case 0: return "오늘"
        case -1: return "어제"
        case 1: return "내일"
        default: return n < 0 ? "\(-n)일 지남" : "\(n)일 후"
        }
    }

    private var subtitle: String {
        var s = "오늘 \(entry.todayCount)"
        if entry.lateCount > 0 { s += " · 지난 \(entry.lateCount)" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.total)")
                        .font(.system(size: family == .systemSmall ? 28 : 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.lateCount > 0 ? Color.orange : Color.green)
                }
                Spacer()
                if family != .systemSmall {
                    Link(destination: URL(string: "haru://todo")!) {
                        Image(systemName: "list.bullet")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.green))
                    }
                }
            }
            Divider().padding(.vertical, family == .systemSmall ? 5 : 8)

            if entry.todos.isEmpty {
                Text("모두 끝냈습니다")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 7 : 4) {
                    ForEach(lines) { line in
                        switch line.kind {
                        case .header(let d, let count):
                            HStack(spacing: 6) {
                                Text(Fmt.string(d, "M/d (E)"))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Fmt.cal.isDateInToday(d) ? Color.accentColor : Color.primary)
                                Text(relative(d))
                                    .font(.caption2)
                                    .foregroundStyle(d < Fmt.cal.startOfDay(for: .now) ? Color.orange : Color.secondary)
                                Spacer(minLength: 0)
                                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.top, line.first ? 0 : 4)
                        case .todo(let t):
                            Button(intent: ToggleTodoIntent(uid: t.id)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "circle")
                                        .font(family == .systemSmall ? .callout : .title3)
                                        .foregroundStyle(.secondary)
                                    Text(t.text)
                                        .font(family == .systemSmall ? .caption : .subheadline)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "haru://todo"))
    }
}

struct HaruTodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HaruTodo", provider: TodoProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("ETHAN MEMO 할 일")
        .description("남은 할 일을 보고 동그라미를 눌러 바로 완료합니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct HaruWidgetBundle: WidgetBundle {
    var body: some Widget {
        HaruTodoWidget()
    }
}
