import Foundation
import SwiftData
import WidgetKit

enum Store {
    /// project.yml의 App Group과 같아야 위젯이 같은 데이터를 봅니다.
    static let appGroup = "group.com.ethanhan.haru"

    static let container: ModelContainer = {
        let schema = Schema([Item.self])
        // 1순위: 앱과 위젯이 공유하는 App Group 저장소
        if let c = try? ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, groupContainer: .identifier(appGroup))) {
            return c
        }
        // App Group이 설정되지 않은 경우: 앱 전용 저장소(위젯은 데이터를 못 봄)
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            fatalError("저장소를 열 수 없습니다: \(error)")
        }
    }()

    static func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func save(_ ctx: ModelContext) {
        try? ctx.save()
        refreshWidgets()
    }
}
