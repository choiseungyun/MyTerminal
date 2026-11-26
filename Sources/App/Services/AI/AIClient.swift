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
    /// 진행 상황 알림 (스트리밍으로 받는 제공자만 부른다. 백그라운드에서 불릴 수 있다)
    var onProgress: ((AIProgress) -> Void)?
}

/// 응답을 받는 중의 단계 (스트리밍 제공자)
enum AIProgress: Equatable {
    /// 답하기 전에 생각하는 중
    case thinking
    /// 답을 쓰는 중
    case answering
    /// 제공자 서버가 바빠(동시 요청 많음·과부하) 잠깐 기다렸다 다시 보내는 중 (몇 번째 다시 보내기)
    case retrying(Int)
}

/// 요청을 보낸 뒤 답을 기다리는 동안의 상태 (화면에 경과 시간·단계 표시)
struct AIWaiting {
    let started = Date()
    var progress: AIProgress?
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
        let guide: String
        if AIHTTP.isBusy(status: status, message: message) {
            guide = "\(name) 서버가 지금 바빠 요청을 받지 못했습니다 (\(status)). 여러 사람이 함께 쓰는 서비스 쪽 사정이라 내 키의 사용 한도와는 관계없습니다. 몇 번 다시 보냈지만 받지 않았습니다. 잠시 뒤 다시 시도하거나 설정 > AI 에서 다른 제공자로 바꿔 보세요."
        } else {
            guide = switch status {
            case 400: "\(provider.subject) 요청을 받아들이지 않았습니다 (400). 고른 모델이 이 기능을 지원하지 않을 수 있습니다. 설정 > AI 에서 다른 모델로 바꿔 보세요."
            case 401: "\(name) API 키가 올바르지 않습니다 (401). 설정(⌘,) > AI 에서 키를 다시 넣어 주세요."
            case 402: "\(name) 결제가 필요합니다 (402). 이 API 키 계정에 결제 수단·크레딧이 없거나, 고른 모델이 지금 요금제에서 열려 있지 않습니다. \(provider.billingHint) 설정 > AI 에서 다른 모델로 바꿔 시도할 수도 있습니다."
            case 403: "이 \(name) API 키로는 요청할 권한이 없습니다 (403). 키의 권한·프로젝트 설정을 확인해 주세요."
            case 404: "\(name) 에서 모델을 찾을 수 없습니다 (404). 설정 > AI 에서 모델을 확인해 주세요."
            case 429: "\(name) 요청이 너무 많거나 사용 한도를 넘었습니다 (429). 잠시 후 다시 시도하거나 \(provider.billingHint)"
            case 500...599: "\(name) 서버가 일시적으로 응답하지 않습니다 (\(status)). 잠시 후 다시 시도해 주세요."
            case 0: "\(provider.subject) 요청을 처리하지 못했습니다."
            default: "\(name) 요청 실패 (\(status))."
            }
        }
        // 서버가 보낸 설명을 그대로 붙인다 (원인을 좁히는 데 필요)
        guard let message, !message.isEmpty else { return guide }
        return guide + "\n서버 메시지: " + message
    }
}

/// 제공자들이 같이 쓰는 HTTP 처리
enum AIHTTP {
    /// 서버가 바쁠 때 다시 보내기 전에 기다리는 시간 (초). 두 번까지 다시 보낸다. 시험에서는 짧게 바꾼다
    nonisolated(unsafe) static var busyRetryDelays: [Double] = [2, 5]

    /// 제공자 서버가 바쁜지 (동시 요청 많음·과부하): 잠깐 뒤 다시 보내면 되는 경우.
    /// 429 라도 사용 한도·요금 초과면 다시 보내도 같으므로 아니다 (서버 메시지로 가린다).
    /// 2026-11-25 iPad 에서 EXAONE "service is busy, too many concurrent requests(600)" 을 한도 초과로 안내했던 문제
    static func isBusy(status: Int, message: String?) -> Bool {
        if status == 503 || status == 529 { return true }
        guard status == 429, let message = message?.lowercased() else { return false }
        return ["busy", "concurrent", "overload", "capacity", "try again later"].contains { message.contains($0) }
    }

    /// 다시 보내기 전에 기다릴 시간: 서버가 Retry-After 로 알려 주면 그것(최대 10초), 아니면 정해 둔 값
    static func retryDelay(_ response: URLResponse, attempt: Int) -> Double {
        if let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after"), let seconds = Double(header) {
            return min(max(seconds, 0), 10)
        }
        return busyRetryDelays[attempt]
    }

    static func key(_ apiKey: () -> String?, _ provider: AIProvider) throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIError.missingAPIKey(provider)
        }
        return key
    }

    /// JSON 을 POST 하고 200 응답 본문을 돌려준다. 서버가 바쁘면 잠깐 기다렸다 다시 보낸다 (onRetry: 몇 번째).
    static func post(_ provider: AIProvider, _ url: URL, headers: [String: String], body: [String: Any], session: URLSession,
                     onRetry: ((Int) -> Void)? = nil) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await postOnce(provider, url, headers: headers, body: body, session: session)
            } catch let busy as Busy where attempt < busyRetryDelays.count {
                let delay = retryDelay(busy.response, attempt: attempt)
                attempt += 1
                onRetry?(attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch let busy as Busy {
                throw busy.error
            }
        }
    }

    /// 서버가 바빠 다시 보내 볼 응답 (마지막이면 error 를 던진다)
    private struct Busy: Error {
        let response: URLResponse
        let error: AIError
    }

    private static func postOnce(_ provider: AIProvider, _ url: URL, headers: [String: String], body: [String: Any], session: URLSession) async throws -> Data {
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
        guard status == 200 else {
            let message = errorMessage(data)
            let error = AIError.http(provider, status: status, message: message)
            if isBusy(status: status, message: message) { throw Busy(response: response, error: error) }
            throw error
        }
        return data
    }

    /// JSON 을 POST 하고 200 응답을 줄 단위로 읽는다 (SSE 스트리밍).
    /// 조각이 계속 오므로 생각이 길어도 `timeoutInterval`(마지막 데이터 뒤 기다리는 시간)에 걸리지 않는다.
    static func stream(_ provider: AIProvider, _ url: URL, headers: [String: String], body: [String: Any], session: URLSession,
                       onRetry: ((Int) -> Void)? = nil) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var attempt = 0
        while true {
            do {
                return try await streamOnce(provider, url, headers: headers, body: body, session: session)
            } catch let busy as Busy where attempt < busyRetryDelays.count {
                let delay = retryDelay(busy.response, attempt: attempt)
                attempt += 1
                onRetry?(attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch let busy as Busy {
                throw busy.error
            }
        }
    }

    private static func streamOnce(_ provider: AIProvider, _ url: URL, headers: [String: String], body: [String: Any], session: URLSession) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapTransport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            do { for try await byte in bytes { data.append(byte) } } catch { throw mapTransport(error) }
            let message = errorMessage(data)
            let error = AIError.http(provider, status: status, message: message)
            if isBusy(status: status, message: message) { throw Busy(response: response, error: error) }
            throw error
        }
        return bytes.lines
    }

    /// URLSession 오류 → 취소 / 네트워크 오류
    static func mapTransport(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? URLError, error.code == .cancelled { return CancellationError() }
        return AIError.network(error.localizedDescription)
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
            // EXAONE: {"result_code": 401, "description": "..."}
            if let description = dict?["description"] as? String, !description.isEmpty { return description }
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
