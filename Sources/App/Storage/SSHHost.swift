import Foundation
import GRDB

/// 저장된 접속 대상(호스트) 하나
struct SSHHost: Identifiable, Hashable, Codable {
    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        /// 키 파일·ssh-agent·ssh 기본 동작에 맡긴다 (키 암호는 macOS 키체인이 기억)
        case auto
        /// 비밀번호를 Keychain 에 저장해 두고 접속 때 자동으로 입력한다
        case password

        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "키 · 에이전트 (자동)"
            case .password: "비밀번호"
            }
        }
    }

    var id: UUID = UUID()
    /// 카드에 보이는 이름 (비우면 주소를 쓴다)
    var name: String = ""
    var hostname: String = ""
    var port: Int?
    var user: String?
    var identityFile: String?
    /// ProxyJump (예: bastion, user@bastion:2222)
    var jumpHost: String?
    /// 경유할 저장된 호스트 (있으면 jumpHost 대신 쓴다. 그 호스트의 키·포트·사용자가 그대로 적용된다)
    var jumpHostID: UUID?
    /// 접속한 뒤 서버에서 실행할 명령 (예: 내부 서버로 한 번 더 ssh)
    var remoteCommand: String?
    var group: String?
    var tags: [String] = []
    var authMethod: AuthMethod = .auto
    /// ~/.ssh/config 에서 가져온 호스트면 그 별칭. 접속 시 `ssh <별칭>` 으로 ssh 설정을 그대로 따른다.
    var sshConfigAlias: String?
    var notes: String?
    var lastConnectedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return sshConfigAlias ?? hostname
    }

    /// 카드 부제목: "ssh, deploy"
    var subtitle: String {
        ["ssh", user].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var isFromSSHConfig: Bool { sshConfigAlias != nil }

    /// 검색어가 이름·주소·사용자·그룹·태그 중 하나에 들어 있으면 true
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [displayName, hostname, user, group, sshConfigAlias, notes].compactMap { $0 } + tags
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

extension SSHHost {
    /// 빠른 연결(user@host, -p 포트)로 저장용 호스트를 만든다.
    init(quickConnect target: QuickConnectTarget) {
        self.init()
        hostname = target.host
        user = target.user
        let parts = target.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        if let index = parts.firstIndex(of: "-p"), index + 1 < parts.count { port = Int(parts[index + 1]) }
    }
}

// MARK: - 데이터베이스 매핑

extension SSHHost: FetchableRecord, PersistableRecord {
    static let databaseTableName = "host"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let lastConnectedAt = Column(CodingKeys.lastConnectedAt)
        static let sshConfigAlias = Column(CodingKeys.sshConfigAlias)
    }

    // `group` 은 SQL 예약어이므로 열 이름은 groupName 으로 둔다.
    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, user, identityFile, jumpHost, jumpHostID, remoteCommand
        case group = "groupName"
        case tags, authMethod, sshConfigAlias, notes, lastConnectedAt, createdAt, updatedAt
    }
}
