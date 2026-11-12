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
    @AppStorage(ThemePrefs.accentKey, store: Store.defaults) private var accentKey = "orange"
    @AppStorage(ThemePrefs.lateKey, store: Store.defaults) private var lateKey = "coral"
    @AppStorage("botEnabled") private var botEnabled = true
    @State private var showBot = false

    @ViewBuilder private var botButton: some View {
        if botEnabled && router.tab != .settings {
            BotOverlay { showBot = true }
        }
    }

    private var botSheet: some View {
        ChatScreen(onClose: { showBot = false })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    var body: some View {
        let themeID = accentKey + "|" + lateKey
        TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
            TodoScreen().id(themeID)
                .tabItem { Label("할 일", systemImage: "checklist") }
                .tag(Tab.todo)
            CalendarScreen().id(themeID)
                .tabItem { Label("캘린더", systemImage: "calendar") }
                .tag(Tab.calendar)
            WikiScreen().id(themeID)
                .tabItem { Label("위키", systemImage: "book.closed") }
                .tag(Tab.wiki)
            SettingsScreen()
                .tabItem { Label("설정", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.hi)
        // 왼쪽 아래 GPT 봇 버튼 → 팝업(질문·등록·음성)
        .overlay(alignment: .bottomLeading) { botButton }
        .sheet(isPresented: $showBot) { botSheet }
        .onChange(of: botEnabled) { _, on in if !on { showBot = false } }
        .onChange(of: themeID) { _, _ in Store.refreshWidgets() }
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
        .alert("GPT 연결 오류",
               isPresented: Binding(get: { asker.lastError != nil }, set: { if !$0 { asker.lastError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(asker.lastError ?? "")
        }
    }
}


/// GPT 봇 버튼: 기본은 오른쪽 아래. 꾹 눌렀다가 끌면 옮길 수 있고, 놓으면 가장 가까운 모서리에 붙음
struct BotOverlay: View {
    var onTap: () -> Void
    @AppStorage("botEdge") private var edge = "r"      // l r t b
    @AppStorage("botFrac") private var frac = 1.0      // 붙은 모서리를 따라 0...1
    @State private var dragPoint: CGPoint?
    @State private var lifted = false

    private let d: CGFloat = 56, m: CGFloat = 10, bottomPad: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let minX = m + d / 2, maxX = max(minX, geo.size.width - m - d / 2)
            let minY = m + d / 2, maxY = max(minY, geo.size.height - bottomPad - d / 2)
            let rest = restPoint(minX, maxX, minY, maxY)
            icon
                .scaleEffect(lifted ? 1.14 : 1)
                .shadow(color: .black.opacity(lifted ? 0.4 : 0.28), radius: lifted ? 14 : 8, y: 4)
                .position(dragPoint ?? rest)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragPoint == nil)
                .onTapGesture(perform: onTap)
                .gesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("botspace")))
                        .onChanged { v in
                            if case .second(true, let drag?) = v {
                                if !lifted { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                                lifted = true
                                dragPoint = CGPoint(x: min(max(drag.location.x, minX), maxX),
                                                    y: min(max(drag.location.y, minY), maxY))
                            }
                        }
                        .onEnded { v in
                            if case .second(true, let drag?) = v {
                                snap(CGPoint(x: min(max(drag.location.x, minX), maxX),
                                             y: min(max(drag.location.y, minY), maxY)),
                                     minX, maxX, minY, maxY)
                            }
                            dragPoint = nil
                            lifted = false
                        }
                )
        }
        .coordinateSpace(name: "botspace")
    }

    private var icon: some View {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Theme.ctaInk)
            .frame(width: d, height: d)
            .background(Circle().fill(Theme.hi))
            .accessibilityLabel("GPT 비서 열기")
            .accessibilityAddTraits(.isButton)
    }

    private func restPoint(_ minX: CGFloat, _ maxX: CGFloat, _ minY: CGFloat, _ maxY: CGFloat) -> CGPoint {
        let f = CGFloat(min(max(frac, 0), 1))
        switch edge {
        case "l": return CGPoint(x: minX, y: minY + f * (maxY - minY))
        case "t": return CGPoint(x: minX + f * (maxX - minX), y: minY)
        case "b": return CGPoint(x: minX + f * (maxX - minX), y: maxY)
        default:  return CGPoint(x: maxX, y: minY + f * (maxY - minY))
        }
    }

    private func snap(_ p: CGPoint, _ minX: CGFloat, _ maxX: CGFloat, _ minY: CGFloat, _ maxY: CGFloat) {
        let dist: [(String, CGFloat)] = [("l", p.x - minX), ("r", maxX - p.x), ("t", p.y - minY), ("b", maxY - p.y)]
        let e = dist.min { $0.1 < $1.1 }?.0 ?? "r"
        edge = e
        if e == "l" || e == "r" { frac = Double((p.y - minY) / max(1, maxY - minY)) }
        else { frac = Double((p.x - minX) / max(1, maxX - minX)) }
    }
}
