import Foundation

/// 호스트 편집 패널의 입력값. 글자 그대로의 입력(포트, 태그)을 검증해 SSHHost 로 만든다.
struct HostForm: Equatable {
    enum ValidationError: Error, Equatable {
        case missingAddress
        case invalidPort
        case invalidJumpHost
        case jumpToSelf

        var message: String {
            switch self {
            case .missingAddress: "주소를 입력하세요."
            case .invalidPort: "포트는 1~65535 사이 숫자여야 합니다."
            case .invalidJumpHost:
                "점프 호스트는 경유할 서버 주소만 씁니다 (예: ubuntu@1.2.3.4:22). 경유 서버의 키가 필요하면 저장된 호스트에서 고르고, 서버에서 실행할 명령은 \"접속 후 실행할 명령\" 칸에 넣으세요."
            case .jumpToSelf: "자기 자신을 경유할 수 없습니다."
            }
        }
    }

    var host: SSHHost
    var portText: String
    var tagsText: String

    init(host: SSHHost) {
        self.host = host
        portText = host.port.map(String.init) ?? ""
        tagsText = host.tags.joined(separator: ", ")
    }

    /// 검증한 뒤 저장할 호스트를 돌려준다.
    func build() throws -> SSHHost {
        var host = host
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.name = host.name.trimmingCharacters(in: .whitespaces)
        if host.hostname.isEmpty {
            guard let alias = host.sshConfigAlias else { throw ValidationError.missingAddress }
            host.hostname = alias
        }

        let port = portText.trimmingCharacters(in: .whitespaces)
        if port.isEmpty {
            host.port = nil
        } else {
            guard let value = Int(port), (1...65535).contains(value) else { throw ValidationError.invalidPort }
            host.port = value
        }

        host.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for key in [\SSHHost.user, \SSHHost.identityFile, \SSHHost.jumpHost, \SSHHost.group, \SSHHost.notes, \SSHHost.remoteCommand] {
            if host[keyPath: key]?.trimmingCharacters(in: .whitespaces).isEmpty == true { host[keyPath: key] = nil }
        }
        if let jump = host.jumpHost?.trimmingCharacters(in: .whitespaces), !jump.isEmpty {
            guard Self.isValidJumpHost(jump) else { throw ValidationError.invalidJumpHost }
            host.jumpHost = jump
        }
        if host.jumpHostID == host.id { throw ValidationError.jumpToSelf }
        return host
    }

    /// ssh -J 형식: [user@]host[:port], 여러 개는 쉼표로 (공백·명령 불가)
    static func isValidJumpHost(_ value: String) -> Bool {
        let hop = #"([A-Za-z0-9._~%+-]+@)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?"#
        return value.range(of: "^\(hop)(,\(hop))*$", options: .regularExpression) != nil
    }

    var validationError: ValidationError? {
        do { _ = try build(); return nil } catch { return error as? ValidationError }
    }
}
