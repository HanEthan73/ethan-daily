import SwiftUI
import SwiftData
import UIKit

/// 할 일: 등록한 날짜별로 묶고, 최신 날짜가 위
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
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("추가", action: add)
                            .buttonStyle(.ink)
                            .controlSize(.small)
                    }
                }
                if dates.isEmpty {
                    Section {
                        Text("할 일이 없습니다. 위에 적으면 오늘 날짜로 등록됩니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(dates, id: \.self) { d in
                    let list = (groups[d] ?? []).sorted {
                        ($0.done ? 1 : 0, Fmt.minutes($0.time)) < ($1.done ? 1 : 0, Fmt.minutes($1.time))
                    }
                    let openN = list.filter { !$0.done }.count
                    let diff = Fmt.daysBetween(today, d)
                    Section {
                        ForEach(list) { item in ItemRow(item: item) { editing = item } }
                    } header: {
                        HStack(spacing: 8) {
                            Text(Fmt.short(d))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(diff == 0 ? Theme.onInk : Color.primary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(diff == 0 ? Color.primary : Color(.tertiarySystemFill)))
                            Text(relative(diff))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(diff < 0 && openN > 0 ? Theme.warn : diff == 0 ? Color.primary : Color.secondary)
                            Spacer()
                            Text("\(list.count - openN)/\(list.count) 완료")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("할 일 \(openCount)")
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
