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
        guard GPTClient.config() != nil else {
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

// MARK: - AI 모델 (무료 Gemini + 유료 OpenAI, 둘 다 OpenAI 호환 API)

enum GPTModel: String, CaseIterable, Identifiable {
    case gemFlash = "gemini-flash-latest"
    case gemLite = "gemini-flash-lite-latest"
    case mini = "gpt-5-mini"
    case full = "gpt-5"
    case fast = "gpt-4o-mini"
    case four = "gpt-4o"
    var id: String { rawValue }
    var isGemini: Bool { rawValue.hasPrefix("gemini") }
    var title: String {
        switch self {
        case .gemFlash: return "Gemini Flash"
        case .gemLite: return "Gemini Flash-Lite"
        case .mini: return "GPT-5 mini"
        case .full: return "GPT-5"
        case .fast: return "GPT-4o mini"
        case .four: return "GPT-4o"
        }
    }
    var label: String { title + (isGemini ? " (무료)" : " (유료)") }
    var desc: String {
        switch self {
        case .gemFlash: return "무료 · 구글 로그인 키 · 똑똑하고 빠름"
        case .gemLite: return "무료 · 더 빠르고 하루 한도 넉넉"
        case .mini: return "OpenAI · 크레딧 충전 필요"
        case .full: return "OpenAI · 더 깊게 생각 · 비쌈"
        case .fast: return "OpenAI · 가장 저렴"
        case .four: return "OpenAI · 균형 잡힌 범용"
        }
    }
    var hasKey: Bool { isGemini ? Keychain.read(account: Keychain.gemini) != nil : Keychain.read() != nil }
    static var current: GPTModel {
        GPTModel(rawValue: UserDefaults.standard.string(forKey: "gptModel") ?? "") ?? .gemFlash
    }
}

struct GPTError: Error {
    let message: String
    var noCredits = false
    var status = 0
    var detail = ""
}

struct AIConfig {
    let model: GPTModel
    let key: String
    var url: URL {
        URL(string: model.isGemini
            ? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
            : "https://api.openai.com/v1/chat/completions")!
    }
}

enum GPTClient {
    /// 고른 모델의 키가 없으면 다른 쪽(무료 Gemini ↔ OpenAI) 키로 자동 전환, 둘 다 없으면 nil
    static func config() -> AIConfig? {
        let g = Keychain.read(account: Keychain.gemini), o = Keychain.read()
        var m = GPTModel.current
        if m.isGemini && g == nil { guard o != nil else { return nil }; m = .mini }
        if !m.isGemini && o == nil { guard g != nil else { return nil }; m = .gemFlash }
        guard let key = m.isGemini ? g : o else { return nil }
        return AIConfig(model: m, key: key)
    }

    /// Gemini: 고른 모델이 무료 한도 0·미지원이면 무료로 열리는 다음 모델로 자동 전환
    private static let gemChains: [String: [String]] = [
        "gemini-flash-latest": ["gemini-flash-latest", "gemini-3.5-flash", "gemini-2.5-flash", "gemini-flash-lite-latest"],
        "gemini-flash-lite-latest": ["gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-2.5-flash-lite", "gemini-2.5-flash"]
    ]
    private static func chain(_ c: AIConfig) -> [String] {
        let m = c.model.rawValue
        guard c.model.isGemini else { return [m] }
        var out: [String] = []
        if let ok = UserDefaults.standard.string(forKey: "gemok." + m) { out.append(ok) }
        for x in gemChains[m] ?? [m] where !out.contains(x) { out.append(x) }
        return out
    }
    private static func send(_ c: AIConfig, _ extra: [String: Any], maxTokens: Int) async throws -> Data {
        var last: GPTError?
        for id in chain(c) {
            let req = try request(c, extra, maxTokens: maxTokens, modelID: id)
            let (data, resp) = try await URLSession.shared.data(for: req)
            do {
                try check(data, resp, gemini: c.model.isGemini)
                if c.model.isGemini { UserDefaults.standard.set(id, forKey: "gemok." + c.model.rawValue) }
                return data
            } catch let e as GPTError {
                last = e
                let retry = c.model.isGemini && (e.status == 429 || e.status == 404 ||
                    (e.status == 400 && e.detail.range(of: "not found|not supported|unknown|invalid model", options: [.regularExpression, .caseInsensitive]) != nil))
                if !retry { throw e }
            }
        }
        throw last ?? GPTError(message: "요청 실패")
    }

    private static func request(_ c: AIConfig, _ extra: [String: Any], maxTokens: Int, modelID: String) throws -> URLRequest {
        var req = URLRequest(url: c.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer " + c.key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": modelID]
        if c.model.isGemini {
            body["max_tokens"] = max(2048, maxTokens * 3)
        } else {
            let reasoning = c.model.rawValue.hasPrefix("gpt-5")
            body["max_completion_tokens"] = reasoning ? maxTokens * 4 : maxTokens
            if reasoning { body["reasoning_effort"] = "low" }
        }
        for (k, v) in extra { body[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func check(_ data: Data, _ resp: URLResponse, gemini: Bool) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code != 200 else { return }
        var detail = ""
        if let j = try? JSONSerialization.jsonObject(with: data) {
            let obj = (j as? [[String: Any]])?.first ?? (j as? [String: Any])
            detail = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
        }
        if code == 401 || code == 403 || (code == 400 && detail.range(of: "api key", options: .caseInsensitive) != nil) {
            throw GPTError(message: "API 키가 올바르지 않습니다. 설정에서 다시 확인하세요.", status: code, detail: detail)
        }
        if code == 429 {
            throw GPTError(message: gemini
                ? "Gemini 무료 모델이 모두 한도에 걸려 기본 모드로 처리했어요. 조금 뒤 다시 하면 Gemini가 답합니다." + (detail.isEmpty ? "" : " · 원문: " + String(detail.prefix(160)))
                : "OpenAI 크레딧이 없거나 한도를 넘어 기본 모드로 처리했어요. 위 모델 선택에서 무료 Gemini로 바꾸면 충전 없이 쓸 수 있어요.",
                noCredits: true, status: code, detail: detail)
        }
        if code >= 500 { throw GPTError(message: "AI 서버가 혼잡합니다. 잠시 후 다시 시도하세요.", status: code, detail: detail) }
        throw GPTError(message: "요청 실패 (\(code)) \(detail)", status: code, detail: detail)
    }

    static func ask(_ prompt: String, maxTokens: Int = 1200) async throws -> String {
        guard let c = config() else {
            throw GPTError(message: "설정에서 무료 Gemini 키(또는 OpenAI 키)를 넣어 주세요.")
        }
        let data = try await send(c, ["messages": [["role": "user", "content": prompt]]], maxTokens: maxTokens)
        let r = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let msg = ((r["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        return (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 도구 호출(챗봇)용: 임의의 body 조각을 합쳐 보내고 응답 JSON을 그대로 돌려줌
    static func raw(_ extra: [String: Any]) async throws -> [String: Any] {
        guard let c = config() else {
            throw GPTError(message: "설정에서 무료 Gemini 키(또는 OpenAI 키)를 넣어 주세요.")
        }
        let data = try await send(c, extra, maxTokens: 1500)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - API 키 보관 (기기 Keychain)

enum Keychain {
    static let gemini = "geminiKey"
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
