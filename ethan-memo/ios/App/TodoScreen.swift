import SwiftUI
import PhotosUI
import SwiftData
import UIKit

/// 할 일: 등록한 날짜별(최신 날짜 위), 날짜 안에서는 최근에 올린 것이 위. 완료한 것은 접어 둠.
struct TodoScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Item> { $0.kindRaw == "todo" }, sort: \Item.day, order: .reverse)
    private var todos: [Item]
    @State private var editing: Item?
    @State private var newText = ""
    @State private var newPhotos: [String] = []
    @State private var picks: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        let today = Fmt.cal.startOfDay(for: .now)
        let pins = todos.filter { $0.pinned && !$0.done }.sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        let groups = Dictionary(grouping: todos.filter { !($0.pinned && !$0.done) }) { $0.day }
        // 다 끝낸 날짜는 숨김 (오늘은 항상 보임 · 기록은 캘린더·위키에)
        let dates = groups.keys.filter { d in
            Fmt.cal.isDateInToday(d) || (groups[d] ?? []).contains { !$0.done }
        }.sorted(by: >)
        let openCount = todos.filter { !$0.done }.count

        NavigationStack {
            List {
                Section {
                    HStack {
                        PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .images) {
                            Image(systemName: "camera")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Theme.pillHi))
                                .overlay(alignment: .topTrailing) {
                                    if !newPhotos.isEmpty {
                                        Text("\(newPhotos.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).background(Capsule().fill(Theme.hi)).offset(x: 5, y: -5)
                                    }
                                }
                        }
                        .buttonStyle(.borderless)
                        TextField("오늘 할 일 추가", text: $newText)
                            .font(.system(size: 15))
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("add", action: add).buttonStyle(.ink)
                    }
                    .rowSurface()
                    if !newPhotos.isEmpty {
                        PhotoEditor(ids: $newPhotos).rowSurface()
                    }
                } footer: {
                    if !dates.isEmpty {
                        // 알약 대신 조용한 한 줄 안내
                        HStack(spacing: 0) {
                            Spacer()
                            ForEach(Array(["← 완료", "일정 등록 →", "꾹 = 고정", "두 번 탭 = 복사"].enumerated()), id: \.offset) { i, t in
                                Text(t).padding(.horizontal, 8)
                                if i < 3 { Rectangle().fill(Theme.line).frame(width: 1, height: 11) }
                            }
                            Spacer()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
                if dates.isEmpty {
                    Section {
                        Text("할 일이 없습니다. 위에 적으면 오늘 날짜로 등록됩니다.")
                            .font(.subheadline).foregroundStyle(.secondary).rowSurface()
                    }
                }
                if !pins.isEmpty {
                    Section {
                        ForEach(pins) { item in ItemRow(item: item, showDate: true) { editing = item } }
                    } header: {
                        HStack {
                            HStack(spacing: 5) {
                                Image(systemName: "pin.fill").font(.system(size: 10)).rotationEffect(.degrees(35)).foregroundStyle(Theme.hi)
                                Text("고정").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(pins.count)개").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        .textCase(nil)
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
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(diff == 0 ? Theme.today : Color.primary)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(diff == 0 ? Theme.today.opacity(0.2) : Theme.pill))
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
            .listRowSpacing(6)
            .refreshable { await SyncService.shared.pullRefresh() }
            .onChange(of: picks) { _, sel in
                guard !sel.isEmpty else { return }
                Task {
                    for p in sel {
                        if let d = try? await p.loadTransferable(type: Data.self), let id = PhotoStore.add(d) { newPhotos.append(id) }
                    }
                    picks = []
                }
            }
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
        let item = Item(kind: .todo, day: .now, text: t)
        item.photoIDs = newPhotos
        ctx.insert(item)
        newPhotos = []
        Store.save(ctx)
        newText = ""
        focused = true
    }
}
