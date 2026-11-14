import Foundation
import Security

/// AI 설정: 제공자·모델(UserDefaults), 제공자별 API 키(Keychain)
final class AISettings: ObservableObject {
    static let shared = AISettings()

    /// 모델 용도
    enum Purpose: String {
        /// 설명·진단
        case explain
        /// ⌘K 명령 추천
        case suggest
    }

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore

    @Published var provider: AIProvider { didSet { defaults.set(provider.rawValue, forKey: "ai.provider") } }
    /// 화면 내용을 보내기 전에 보낼 내용을 보여 주고 확인받는다
    @Published var confirmBeforeSend: Bool { didSet { defaults.set(confirmBeforeSend, forKey: "ai.confirmBeforeSend") } }
    /// 키가 저장된 제공자 (키 자체는 화면에 들고 있지 않는다)
    @Published private(set) var providersWithKey: Set<AIProvider>
    /// 제공자·용도별 모델 ("anthropic.explain" → "claude-opus-5-5")
    @Published private var models: [String: String]

    init(defaults: UserDefaults = .standard, keyStore: APIKeyStore = .keychain) {
        self.defaults = defaults
        self.keyStore = keyStore
        provider = defaults.string(forKey: "ai.provider").flatMap(AIProvider.init) ?? .anthropic
        confirmBeforeSend = defaults.object(forKey: "ai.confirmBeforeSend") as? Bool ?? true
        providersWithKey = Set(AIProvider.allCases.filter { keyStore.read($0) != nil })

        var models = defaults.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
        // 예전 설정(Claude 만 있던 때) 옮기기
        if let old = defaults.string(forKey: "ai.model"), models["anthropic.explain"] == nil { models["anthropic.explain"] = old }
        if let old = defaults.string(forKey: "ai.suggestModel"), models["anthropic.suggest"] == nil { models["anthropic.suggest"] = old }
        self.models = models
    }

    func model(for provider: AIProvider, _ purpose: Purpose) -> String {
        models["\(provider.rawValue).\(purpose.rawValue)"] ?? provider.defaultModel
    }

    func setModel(_ model: String, for provider: AIProvider, _ purpose: Purpose) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        models["\(provider.rawValue).\(purpose.rawValue)"] = trimmed
        defaults.set(models, forKey: "ai.models")
    }

    /// 지금 제공자의 설명·진단 모델
    var model: String { model(for: provider, .explain) }
    /// 지금 제공자의 ⌘K 모델
    var suggestModel: String { model(for: provider, .suggest) }

    /// 지금 제공자의 키가 있는지
    var hasAPIKey: Bool { providersWithKey.contains(provider) }
    func hasKey(_ provider: AIProvider) -> Bool { providersWithKey.contains(provider) }

    func apiKey(_ provider: AIProvider) -> String? { keyStore.read(provider) }

    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyStore.write(provider, trimmed)
        if keyStore.read(provider) != nil { providersWithKey.insert(provider) }
    }

    func deleteAPIKey(for provider: AIProvider) {
        keyStore.delete(provider)
        providersWithKey.remove(provider)
    }
}

/// 제공자별 API 키 저장소 (테스트에서는 메모리 저장소를 쓴다)
struct APIKeyStore {
    var read: (AIProvider) -> String?
    var write: (AIProvider, String) -> Void
    var delete: (AIProvider) -> Void

    static let keychainService = "kr.weare.myterminal.ai"

    static let keychain: APIKeyStore = {
        func base(_ provider: AIProvider) -> [CFString: Any] {
            [kSecClass: kSecClassGenericPassword,
             kSecAttrService: keychainService,
             kSecAttrAccount: provider.keychainAccount]
        }
        return APIKeyStore(
            read: { provider in
                var query = base(provider)
                query[kSecReturnData] = true
                query[kSecMatchLimit] = kSecMatchLimitOne
                var result: AnyObject?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
                return key
            },
            write: { provider, key in
                let data = Data(key.utf8)
                if SecItemUpdate(base(provider) as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
                    var query = base(provider)
                    query[kSecValueData] = data
                    query[kSecAttrLabel] = "MyTerminal \(provider.shortName) API 키"
                    SecItemAdd(query as CFDictionary, nil)
                }
            },
            delete: { provider in SecItemDelete(base(provider) as CFDictionary) })
    }()

    static func memory(_ initial: [AIProvider: String] = [:]) -> APIKeyStore {
        final class Box { var values: [AIProvider: String]; init(_ v: [AIProvider: String]) { values = v } }
        let box = Box(initial)
        return APIKeyStore(read: { box.values[$0] }, write: { box.values[$0] = $1 }, delete: { box.values[$0] = nil })
    }
}
