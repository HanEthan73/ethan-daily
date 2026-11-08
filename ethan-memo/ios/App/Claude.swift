import Foundation
import SwiftData
import Security
import Observation

// MARK: - 질문 처리 상태

@MainActor
@Observable
final class Asker {
    static let shared = Asker()
    var busy: Set<String> = []
    var lastError: String?

    func ask(_ item: Item, ctx: ModelContext) {
        guard !busy.contains(item.uid) else { return }
        guard Keychain.read() != nil else {
            lastError = "설정 탭에서 Claude API 키를 먼저 입력하세요. 키 없이 쓰려면 ‘Claude 앱으로’ 버튼으로 공유하면 됩니다."
            return
        }
        busy.insert(item.uid)
        let prompt = Prompt.make(item)
        Task {
            do {
                let answer = try await ClaudeClient.ask(prompt)
                item.answer = answer
                item.answeredAt = .now
                try? ctx.save()
            } catch {
                lastError = (error as? ClaudeError)?.message ?? error.localizedDescription
            }
            busy.remove(item.uid)
        }
    }
}

enum Prompt {
    static func make(_ item: Item) -> String {
        let kind: String
        let extra: String
        switch item.kind {
        case .memo:
            kind = "메모해 둔 궁금증이나 생각"
            extra = "질문이 아니라 메모라면 그 주제에서 알면 좋을 핵심과, 이어서 생각해 볼 질문 1개를 주세요."
        case .todo:
            kind = "할 일로 적어 둔 것"
            extra = "이 할 일을 끝내기 위한 구체적인 단계와 놓치기 쉬운 점을 알려 주세요."
        case .event:
            kind = "일정으로 잡아 둔 것"
            extra = "이 일정을 위해 미리 준비하거나 확인할 것을 알려 주세요."
        }
        var when = Fmt.string(item.day, "yyyy년 M월 d일")
        if let e = item.endDay { when += " ~ " + Fmt.string(e, "M월 d일") }
        if let t = item.time { when += " " + Fmt.time(t) }
        return """
        다음은 사용자가 \(when)에 \(kind)입니다. 한국어로 답하세요.
        - 첫 줄은 "한 줄 요약: "으로 시작하는 쉬운 한 문장.
        - 이어서 핵심을 간결하게 (필요하면 "1." "2." 같은 짧은 번호 목록).
        - 마크다운 기호(#, **, 표)는 쓰지 말고 일반 텍스트로. 600자 이내.
        - \(extra)

        내용:
        \(item.text)
        """
    }
}

// MARK: - Anthropic API

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case opus = "claude-opus-5-5"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sonnet: return "Sonnet 5.5 (기본)"
        case .haiku: return "Haiku 5.5 (빠름·저렴)"
        case .opus: return "Opus 5.5 (깊이)"
        }
    }
    static var current: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .sonnet
    }
}

struct ClaudeError: Error {
    let message: String
}

enum ClaudeClient {
    static func ask(_ prompt: String, maxTokens: Int = 1200) async throws -> String {
        guard let key = Keychain.read(), !key.isEmpty else {
            throw ClaudeError(message: "API 키가 없습니다. 설정 탭에서 입력하세요.")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": ClaudeModel.current.rawValue,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
            let detail = (try? JSONDecoder().decode(E.self, from: data))?.error.message ?? ""
            switch code {
            case 401: throw ClaudeError(message: "API 키가 올바르지 않습니다. 설정에서 다시 확인하세요.")
            case 429: throw ClaudeError(message: "요청이 많습니다. 잠시 후 다시 시도하세요.")
            case 529, 503: throw ClaudeError(message: "Claude 서버가 혼잡합니다. 잠시 후 다시 시도하세요.")
            default: throw ClaudeError(message: "요청 실패 (\(code)) \(detail)")
            }
        }
        struct R: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        let text = r.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - API 키 보관 (기기 Keychain)

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "haru.claude",
        kSecAttrAccount as String: "apiKey"
    ]

    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}
