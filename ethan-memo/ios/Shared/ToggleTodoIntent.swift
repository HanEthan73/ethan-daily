import AppIntents
import SwiftData
import WidgetKit

/// 위젯의 동그라미를 누르면 앱을 열지 않고 완료 처리
struct ToggleTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "할 일 완료 전환"
    static var isDiscoverable: Bool = false

    @Parameter(title: "ID")
    var uid: String

    init() {}
    init(uid: String) { self.uid = uid }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = Store.container.mainContext
        let id = uid
        let fd = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == id })
        if let item = try ctx.fetch(fd).first {
            item.done.toggle()
            item.doneAt = item.done ? .now : nil
            try ctx.save()
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
