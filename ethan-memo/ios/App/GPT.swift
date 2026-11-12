import Foundation
import SwiftData
import Security
import Observation
import UIKit

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
            // API 키 없이: ChatGPT 앱(구독)으로 질문을 열고, 답은 복사해 와서 붙여넣기
            GPTLink.open(Prompt.make(item))
            return
        }
        busy.insert(item.uid)
        let prompt = Prompt.make(item)
        Task {
            do {
                let answer = try await GPTClient.ask(prompt)
                item.answer = answer
                item.answeredAt = .now
                Store.save(ctx)
            } catch {
                lastError = (error as? GPTError)?.message ?? error.localizedDescription
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

// MARK: - OpenAI API

enum GPTModel: String, CaseIterable, Identifiable {
    case mini = "gpt-5-mini"
    case full = "gpt-5"
    case fast = "gpt-4o-mini"
    case four = "gpt-4o"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mini: return "GPT-5 mini (기본)"
        case .full: return "GPT-5 (깊이)"
        case .fast: return "GPT-4o mini (빠름·저렴)"
        case .four: return "GPT-4o"
        }
    }
    var title: String {
        switch self {
        case .mini: return "GPT-5 mini"
        case .full: return "GPT-5"
        case .fast: return "GPT-4o mini"
        case .four: return "GPT-4o"
        }
    }
    var desc: String {
        switch self {
        case .mini: return "빠르고 저렴한 기본 모델"
        case .full: return "더 깊게 생각해 정확도↑ · 느리고 비쌈"
        case .fast: return "가장 빠르고 저렴"
        case .four: return "균형 잡힌 범용 모델"
        }
    }
    static var current: GPTModel {
        GPTModel(rawValue: UserDefaults.standard.string(forKey: "gptModel") ?? "") ?? .mini
    }
}

struct GPTError: Error {
    let message: String
    var noCredits = false
}

enum GPTClient {
    static func ask(_ prompt: String, maxTokens: Int = 1200) async throws -> String {
        guard let key = Keychain.read(), !key.isEmpty else {
            throw GPTError(message: "API 키가 없습니다. 설정 탭에서 입력하세요.")
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = GPTModel.current.rawValue
        let reasoning = model.hasPrefix("gpt-5")
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": reasoning ? maxTokens * 4 : maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        if reasoning { body["reasoning_effort"] = "low" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
            let detail = (try? JSONDecoder().decode(E.self, from: data))?.error.message ?? ""
            switch code {
            case 401: throw GPTError(message: "API 키가 올바르지 않습니다. 설정에서 다시 확인하세요.")
            case 429: throw GPTError(message: "요청이 많거나 사용 한도를 넘었습니다. 잠시 후 다시 시도하세요.")
            case 500, 503: throw GPTError(message: "OpenAI 서버가 혼잡합니다. 잠시 후 다시 시도하세요.")
            default: throw GPTError(message: "요청 실패 (\(code)) \(detail)")
            }
        }
        struct R: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        let text = r.choices.first?.message.content ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension GPTClient {
    /// 도구 호출(챗봇)용: 임의의 body 조각을 합쳐 보내고 응답 JSON을 그대로 돌려줌
    static func raw(_ extra: [String: Any]) async throws -> [String: Any] {
        guard let key = Keychain.read(), !key.isEmpty else {
            throw GPTError(message: "설정 탭에서 OpenAI API 키를 먼저 입력하세요.")
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = GPTModel.current.rawValue
        let reasoning = model.hasPrefix("gpt-5")
        var body: [String: Any] = ["model": model, "max_completion_tokens": reasoning ? 4000 : 1500]
        if reasoning { body["reasoning_effort"] = "low" }
        for (k, v) in extra { body[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
            let detail = (try? JSONDecoder().decode(E.self, from: data))?.error.message ?? ""
            switch code {
            case 401: throw GPTError(message: "API 키가 올바르지 않습니다. 설정에서 다시 확인하세요.")
            case 429:
                let out = detail.range(of: "credit|quota|billing", options: [.regularExpression, .caseInsensitive]) != nil
                throw GPTError(message: out ? "OpenAI 크레딧이 없어 무료 모드로 처리했어요. platform.openai.com → Billing에서 충전하면 GPT가 직접 답합니다 (ChatGPT 구독과는 별개)." : "요청이 많거나 사용 한도를 넘었습니다. 잠시 후 다시 시도하세요.", noCredits: out)
            default: throw GPTError(message: "요청 실패 (\(code)) \(detail)")
            }
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - API 키 보관 (기기 Keychain)

enum Keychain {
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "haru.openai",
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String = "apiKey") {
        SecItemDelete(base(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String = "apiKey") -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}


/// API 키 없이 ChatGPT 앱·웹(구독)으로 열기: 질문을 복사해 두고 chatgpt.com/?q= 로 엶
enum GPTLink {
    @MainActor static func open(_ prompt: String) {
        UIPasteboard.general.string = prompt
        let q = String(prompt.prefix(6000)).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        if let url = URL(string: "https://chatgpt.com/?q=" + q) { UIApplication.shared.open(url) }
    }
}
