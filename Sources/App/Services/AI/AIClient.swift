import Foundation

/// 제공자와 상관없는 요청 내용
struct AIRequest {
    var model: String
    var system: String
    var user: String
    /// 응답 JSON 스키마 (모든 object 에 additionalProperties: false, 모든 속성 required)
    var schema: [String: Any]
    /// 생각 깊이: low / medium (제공자마다 맞는 이름으로 바꿔 보낸다)
    var effort: String = "medium"
    /// 생각 토큰을 포함한 최대 출력 길이
    var maxTokens: Int = 16000
}

/// AI 제공자 클라이언트. 요청을 보내고 스키마에 맞는 JSON 을 `T` 로 돌려준다.
protocol AIClient {
    var provider: AIProvider { get }
    func send<T: Decodable>(_ request: AIRequest, as type: T.Type) async throws -> T
}

enum AIError: LocalizedError, Equatable {
    case missingAPIKey(AIProvider)
    case network(String)
    case http(AIProvider, status: Int, message: String?)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.shortName) API 키가 없습니다. 설정(⌘,) > AI 에서 키를 넣어 주세요."
        case .network(let message):
            "네트워크 오류: \(message)"
        case .http(let provider, let status, let message):
            Self.httpDescription(provider, status: status, message: message)
        case .refused:
            "AI 가 이 요청에 답하지 않았습니다."
        case .truncated:
            "답이 너무 길어 중간에 끊겼습니다. 범위를 좁혀 다시 물어 주세요."
        case .badResponse:
            "응답을 읽지 못했습니다. 다시 시도해 주세요."
        }
    }
}

extension AIError {
    static func httpDescription(_ provider: AIProvider, status: Int, message: String?) -> String {
        let name = provider.shortName
        let guide: String = switch status {
        case 400: "\(name)가 요청을 받아들이지 않았습니다 (400). 고른 모델이 이 기능을 지원하지 않을 수 있습니다. 설정 > AI 에서 다른 모델로 바꿔 보세요."
        case 401: "\(name) API 키가 올바르지 않습니다 (401). 설정(⌘,) > AI 에서 키를 다시 넣어 주세요."
        case 402: "\(name) 결제가 필요합니다 (402). 이 API 키 계정에 결제 수단·크레딧이 없거나, 고른 모델이 지금 요금제에서 열려 있지 않습니다. \(provider.billingHint) 설정 > AI 에서 다른 모델로 바꿔 시도할 수도 있습니다."
        case 403: "이 \(name) API 키로는 요청할 권한이 없습니다 (403). 키의 권한·프로젝트 설정을 확인해 주세요."
        case 404: "\(name) 에서 모델을 찾을 수 없습니다 (404). 설정 > AI 에서 모델을 확인해 주세요."
        case 429: "\(name) 요청이 너무 많거나 사용 한도를 넘었습니다 (429). 잠시 후 다시 시도하거나 \(provider.billingHint)"
        case 500...599: "\(name) 서버가 일시적으로 응답하지 않습니다 (\(status)). 잠시 후 다시 시도해 주세요."
        case 0: "\(name)가 요청을 처리하지 못했습니다."
        default: "\(name) 요청 실패 (\(status))."
        }
        // 서버가 보낸 설명을 그대로 붙인다 (원인을 좁히는 데 필요)
        guard let message, !message.isEmpty else { return guide }
        return guide + "\n서버 메시지: " + message
    }
}

/// 세 제공자가 같이 쓰는 HTTP 처리
enum AIHTTP {
    static func key(_ apiKey: () -> String?, _ provider: AIProvider) throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIError.missingAPIKey(provider)
        }
        return key
    }

    /// JSON 을 POST 하고 200 응답 본문을 돌려준다.
    static func post(_ provider: AIProvider, _ url: URL, headers: [String: String], body: [String: Any], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIError.http(provider, status: status, message: errorMessage(data)) }
        return data
    }

    /// 오류 응답에서 설명을 꺼낸다.
    /// 보통 {"error": {"message": ...}} 이지만 Google 은 [{"error": ...}] 배열로 보내기도 하고,
    /// 프록시·게이트웨이 오류는 JSON 이 아닐 수 있어 글자 그대로 일부를 돌려준다.
    static func errorMessage(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let dict = (object as? [String: Any]) ?? (object as? [[String: Any]])?.first
            if let error = dict?["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty { return message }
                if let status = error["status"] as? String { return status }
            }
            if let error = dict?["error"] as? String, !error.isEmpty { return error }
            if let message = dict?["message"] as? String, !message.isEmpty { return message }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }

    /// 모델이 돌려준 JSON 글자를 `T` 로 읽는다.
    static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw AIError.badResponse
        }
        return value
    }
}
