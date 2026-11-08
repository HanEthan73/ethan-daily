import SwiftUI
import SwiftData
import UIKit

/// 할 일: 등록한 날짜별(최신 날짜 위), 날짜 안에서는 최근에 올린 것이 위. 완료한 것은 접어 둠.
struct TodoScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Item> { $0.kindRaw == "todo" }, sort: \Item.day, order: .reverse)
    private var todos: [Item]
    @State private var editing: Item?
    @State private var newText = ""
    @FocusState private var focused: Bool

    var body: some View {
        let today = Fmt.cal.startOfDay(for: .now)
        let groups = Dictionary(grouping: todos) { $0.day }
        let dates = groups.keys.sorted(by: >)
        let openCount = todos.filter { !$0.done }.count

        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("오늘 할 일 추가", text: $newText)
                            .font(.system(size: 15))
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("추가", action: add).buttonStyle(.ink)
                    }
                    .rowSurface()
                } footer: {
                    if !dates.isEmpty {
                        HStack(spacing: 8) {
                            Spacer()
                            Text("← 밀면 완료").foregroundStyle(Theme.swipeDone)
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.swipeDone.opacity(0.14)))
                            Text("밀면 일정 등록 →").foregroundStyle(Theme.swipeEvent)
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.swipeEvent.opacity(0.15)))
                            Spacer()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.top, 4)
                    }
                }
                if dates.isEmpty {
                    Section {
                        Text("할 일이 없습니다. 위에 적으면 오늘 날짜로 등록됩니다.")
                            .font(.subheadline).foregroundStyle(.secondary).rowSurface()
                    }
                }
                ForEach(dates, id: \.self) { d in
                    let list = groups[d] ?? []
                    let open = list.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt }
                    let done = list.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
                    let diff = Fmt.daysBetween(today, d)
                    Section {
                        ForEach(open) { item in ItemRow(item: item) { editing = item } }
                        DoneFold(items: done, editing: $editing)
                    } header: {
                        HStack(spacing: 8) {
                            Text(Fmt.short(d))
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(diff == 0 ? Theme.today : Color.primary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6).fill(diff == 0 ? Theme.today.opacity(0.14) : Theme.line.opacity(0.6)))
                            Text(relative(diff))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(diff < 0 && !open.isEmpty ? Theme.warn : diff == 0 ? Theme.today : Color.secondary)
                            if let h = Holidays.shared.short(d) {
                                Text(h).font(.system(size: 11)).foregroundStyle(Theme.sun)
                            }
                            Spacer()
                            Text("\(done.count)/\(list.count) 완료")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .spaceGray()
            .navigationTitle("할 일 \(openCount)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { EditSheet(item: $0) }
        }
    }

    private func relative(_ diff: Int) -> String {
        switch diff {
        case 0: return "오늘"
        case -1: return "어제"
        case 1: return "내일"
        default: return diff < 0 ? "\(-diff)일 전" : "\(diff)일 후"
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { focused = true; return }
        ctx.insert(Item(kind: .todo, day: .now, text: t))
        Store.save(ctx)
        newText = ""
        focused = true
    }
}
