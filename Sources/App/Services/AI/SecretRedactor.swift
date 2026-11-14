import Foundation

/// AI 에 보내기 전에 비밀번호·토큰·키처럼 보이는 문자열을 가린다.
///
/// 완벽하지 않으므로 보낼 내용을 미리 보여 주는 화면과 함께 쓴다.
enum SecretRedactor {
    static let mask = "[가림]"

    private struct Rule {
        let regex: NSRegularExpression
        /// 남길 앞부분 그룹 번호 (예: "password=" 는 남기고 값만 가림). 0 이면 전체를 가림.
        let keepGroup: Int
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, keep: Int = 0) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), keepGroup: keep)
        }
        return [
            // 개인 키 블록 전체
            rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
            // Authorization: Bearer xxx / Basic xxx
            rule(#"(authorization:\s*(?:bearer|basic|token)\s+)[^\s"']+"#, keep: 1),
            // 키=값 / 키: 값 형태 (password, secret, token, api_key 등)
            rule(#"((?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|auth)[\w.-]*\s*[:=]\s*["']?)[^\s"',;]+"#, keep: 1),
            // 명령줄 옵션: --password xxx, -p'xxx' 는 오탐이 많아 긴 옵션만
            rule(#"(--(?:password|passwd|token|secret|api-key)[= ]\s*)[^\s]+"#, keep: 1),
            // URL 안의 user:password@
            rule(#"(\w+://[^\s:/@]+:)[^\s@/]+(@)"#, keep: 1),
            // 잘 알려진 토큰 형식
            rule(#"\bsk-ant-[A-Za-z0-9_-]{10,}"#),
            rule(#"\bsk-[A-Za-z0-9]{20,}"#),
            rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
            rule(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
            rule(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
            rule(#"\bAIza[0-9A-Za-z_-]{30,}"#),
            // JWT
            rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        ]
    }()

    /// 가린 결과와 가린 개수
    static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.matches(in: result, range: range)
            guard !matches.isEmpty else { continue }
            count += matches.count
            // 뒤에서부터 바꿔야 앞 범위가 흔들리지 않는다
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result) else { continue }
                var replacement = mask
                if rule.keepGroup > 0, let kept = Range(match.range(at: rule.keepGroup), in: result) {
                    replacement = String(result[kept]) + mask
                    // URL 의 @ 처럼 뒤에 남길 그룹
                    if match.numberOfRanges > rule.keepGroup + 1,
                       let tail = Range(match.range(at: rule.keepGroup + 1), in: result) {
                        replacement += String(result[tail])
                    }
                }
                result.replaceSubrange(whole, with: replacement)
            }
        }
        return (result, count)
    }
}
