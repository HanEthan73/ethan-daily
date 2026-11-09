import SwiftUI
import SwiftData

@main
struct HaruApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(Store.container)
    }
}

enum Tab: Hashable { case todo, calendar, wiki, settings }

struct RootView: View {
    private var router = Router.shared
    @Environment(\.scenePhase) private var phase
    private var asker = Asker.shared

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
            TodoScreen()
                .tabItem { Label("할 일", systemImage: "checklist") }
                .tag(Tab.todo)
            CalendarScreen()
                .tabItem { Label("캘린더", systemImage: "calendar") }
                .tag(Tab.calendar)
            WikiScreen()
                .tabItem { Label("위키", systemImage: "book.closed") }
                .tag(Tab.wiki)
            SettingsScreen()
                .tabItem { Label("설정", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.hi)
        // 좌우로 쓸어서 할 일 ↔ 캘린더 ↔ 위키
        .simultaneousGesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .global)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 90, abs(dx) > abs(dy) * 2 else { return }
                    guard let next = TabSwipe.neighbor(of: router.tab, dx < 0 ? 1 : -1) else { return }
                    guard !TabSwipe.isBlocked(at: v.startLocation) else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { router.tab = next }
                }
        )
        // 위젯의 목록 버튼(haru://todo)으로 열면 할 일 탭으로
        .onOpenURL { url in
            if url.host == "import" {
                let ctx = Store.container.mainContext
                _ = try? Backup.importCode(url.absoluteString, into: ctx)
                router.tab = .todo
                return
            }
            if url.host == "todo" { router.tab = .todo }
            if url.host == "calendar" { router.tab = .calendar }
            if url.host == "wiki" { router.tab = .wiki }
        }
        .onChange(of: phase) { _, p in
            if p == .background { Store.refreshWidgets() }
            if p == .active {
                SyncService.shared.schedule(0.3)
                Task { await Holidays.shared.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Store.changed)) { _ in
            SyncService.shared.schedule()
        }
        .task {
            await Holidays.shared.refresh()
            // 열려 있는 동안 1분마다 다른 기기 변경 사항 받기
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if phase == .active { await SyncService.shared.run() }
            }
        }
        .alert("Claude 연결 오류",
               isPresented: Binding(get: { asker.lastError != nil }, set: { if !$0 { asker.lastError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(asker.lastError ?? "")
        }
    }
}
