import Foundation
import SwiftData
import WidgetKit

enum Store {
    /// project.yml의 App Group과 같아야 위젯이 같은 데이터를 봅니다.
    static let appGroup = "group.com.ethanhan.haru"
    static let changed = Notification.Name("ethanmemo.changed")
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static let container: ModelContainer = {
        let schema = Schema([Item.self, WikiPage.self])
        if let c = try? ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, groupContainer: .identifier(appGroup))) {
            return c
        }
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            fatalError("저장소를 열 수 없습니다: \(error)")
        }
    }()

    static func refreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 사용자가 바꾼 내용을 저장: 수정 시각을 찍고, 지운 것은 동기화용으로 기록
    static func save(_ ctx: ModelContext) {
        let now = Date()
        for m in ctx.insertedModelsArray + ctx.changedModelsArray {
            if let i = m as? Item { i.updatedAt = now }
            if let p = m as? WikiPage { p.updatedAt = now }
        }
        var dead = Dead.load()
        for m in ctx.deletedModelsArray {
            if let i = m as? Item { dead[i.uid] = now.timeIntervalSince1970 * 1000 }
            if let p = m as? WikiPage { dead[p.uid] = now.timeIntervalSince1970 * 1000 }
        }
        Dead.save(dead)
        try? ctx.save()
        refreshWidgets()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// 지운 기록 (다른 기기에서도 지워지도록 동기화할 때 사용)
enum Dead {
    static func load() -> [String: Double] {
        guard let d = Store.defaults.data(forKey: "dead"),
              let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }
    static func save(_ m: [String: Double]) {
        if let d = try? JSONEncoder().encode(m) { Store.defaults.set(d, forKey: "dead") }
    }
}
