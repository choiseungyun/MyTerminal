import Foundation

/// AI 제공자. 설정에서 고르고, 제공자마다 API 키와 모델을 따로 저장한다.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openai
    case gemini
    case exaone

    var id: String { rawValue }

    /// 설정 화면 이름
    var title: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openai: "ChatGPT (OpenAI)"
        case .gemini: "Gemini (Google)"
        case .exaone: "EXAONE (LG AI연구원)"
        }
    }

    /// 화면 문구용 짧은 이름 ("Claude가 살펴보는 중…")
    var shortName: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .exaone: "EXAONE"
        }
    }

    /// 주격 조사를 붙인 이름 ("Claude가", "EXAONE이"): 엑사원은 받침이 있다
    var subject: String {
        switch self {
        case .exaone: shortName + "이"
        default: shortName + "가"
        }
    }

    /// 키를 만드는 곳 (설정 화면 안내)
    var keyConsole: String {
        switch self {
        case .anthropic: "console.anthropic.com"
        case .openai: "platform.openai.com"
        case .gemini: "aistudio.google.com"
        case .exaone: "docs.exaone.ai"
        }
    }

    /// 결제·한도 설정 안내 (402·429)
    var billingHint: String {
        switch self {
        case .anthropic: "console.anthropic.com 의 Billing 에서 크레딧을 확인해 주세요."
        case .openai: "platform.openai.com 의 Billing 에서 결제 수단·크레딧을 확인해 주세요."
        case .gemini: "aistudio.google.com 에서 이 키 프로젝트의 결제(Billing)·요금제를 확인해 주세요."
        case .exaone: "docs.exaone.ai 에 로그인해 이 키의 사용 한도를 확인해 주세요 (My Profile 에서 하루 한도를 늘리는 선택 동의가 있습니다)."
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        case .gemini: "AIza…"
        case .exaone: "EXAONE API 키"
        }
    }

    /// 고를 수 있는 모델 (공식 문서 기준, 2026-11). 목록에 없는 모델은 직접 입력할 수 있다.
    var presets: [(id: String, title: String)] {
        switch self {
        case .anthropic:
            [("claude-opus-5-5", "Claude Opus 5.5 (가장 정확)"),
             ("claude-sonnet-5-5", "Claude Sonnet 5.5 (균형)"),
             ("claude-haiku-5-5", "Claude Haiku 5.5 (가장 빠름)")]
        case .openai:
            [("gpt-6-astra", "GPT-6 Astra (가장 정확)"),
             ("gpt-6.1-sol", "GPT-6.1 Sol (균형)"),
             ("gpt-6.1-terra", "GPT-6.1 Terra (빠름)"),
             ("gpt-6-luna", "GPT-6 Luna (가장 저렴)")]
        case .gemini:
            [("gemini-4-carbon", "Gemini 4 Carbon (가장 정확)"),
             ("gemini-4-argon", "Gemini 4 Argon (균형)"),
             ("gemini-3.8-flash", "Gemini 3.8 Flash (빠름)"),
             ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite (가장 저렴)")]
        case .exaone:
            [("k-exaone_v2.5", "K-EXAONE 2.5 (한국어 특화)")]
        }
    }

    var defaultModel: String { presets[0].id }

    func isPreset(_ model: String) -> Bool { presets.contains { $0.id == model } }

    /// 키체인 계정 이름 (Claude 는 예전 이름 그대로)
    var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openai: "openai-api-key"
        case .gemini: "gemini-api-key"
        case .exaone: "exaone-api-key"
        }
    }
}
