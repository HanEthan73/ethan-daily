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

enum Tab: Hashable { case calendar, todo, settings }

struct RootView: View {
    @State private var tab: Tab = .todo
    @Environment(\.scenePhase) private var phase
    private var asker = Asker.shared

    var body: some View {
        TabView(selection: $tab) {
            TodoScreen()
                .tabItem { Label("할 일", systemImage: "checklist") }
                .tag(Tab.todo)
            CalendarScreen()
                .tabItem { Label("캘린더", systemImage: "calendar") }
                .tag(Tab.calendar)
            SettingsScreen()
                .tabItem { Label("설정", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // 위젯의 목록 버튼(haru://todo)으로 열면 할 일 탭으로
        .onOpenURL { url in
            if url.host == "todo" { tab = .todo }
            if url.host == "calendar" { tab = .calendar }
        }
        .onChange(of: phase) { _, p in
            if p == .background { Store.refreshWidgets() }
        }
        .alert("Claude 연결 오류",
               isPresented: Binding(get: { asker.lastError != nil }, set: { if !$0 { asker.lastError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(asker.lastError ?? "")
        }
    }
}
