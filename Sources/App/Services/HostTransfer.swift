import Foundation

/// 접속 목록 내보내기·가져오기 (JSON 파일)
///
/// 파일에 넣지 않는 것: 비밀번호(Keychain), 최근 접속 시간, 만든·고친 시각.
/// 파일이 다른 사람에게 전달될 수 있으므로 비밀번호는 절대 내보내지 않는다.
enum HostTransfer {
    static let format = "myterminal.hosts"
    static let currentVersion = 1

    /// 파일 전체
    struct File: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var hosts: [Entry]
    }

    /// 호스트 하나. 앱 내부 모델과 분리해 두어 모델이 바뀌어도 파일 형식은 유지한다.
    struct Entry: Codable, Equatable {
        var id: UUID?
        var name: String?
        var hostname: String
        var port: Int?
        var user: String?
        var identityFile: String?
        var jumpHost: String?
        /// 경유할 호스트의 id (같은 파일 안의 호스트를 가리킨다)
        var jumpHostID: UUID?
        var remoteCommand: String?
        var group: String?
        var tags: [String]?
        /// "auto" | "password"
        var authMethod: String?
        var sshConfigAlias: String?
        var notes: String?
    }

    enum ImportError: LocalizedError, Equatable {
        case invalidJSON
        case notHostFile
        case unsupportedVersion(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidJSON: "JSON 파일을 읽을 수 없습니다."
            case .notHostFile: "MyTerminal 접속 목록 파일이 아닙니다."
            case .unsupportedVersion(let v): "이 앱보다 새 버전(\(v))에서 만든 파일입니다. 앱을 업데이트하세요."
            case .empty: "파일에 호스트가 없습니다."
            }
        }
    }

    // MARK: - 내보내기

    static func export(_ hosts: [SSHHost], at date: Date = Date()) throws -> Data {
        let file = File(format: format, version: currentVersion, exportedAt: date, hosts: hosts.map(entry))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func entry(_ host: SSHHost) -> Entry {
        Entry(
            id: host.id,
            name: host.name.isEmpty ? nil : host.name,
            hostname: host.hostname,
            port: host.port,
            user: host.user,
            identityFile: host.identityFile,
            jumpHost: host.jumpHost,
            jumpHostID: host.jumpHostID,
            remoteCommand: host.remoteCommand,
            group: host.group,
            tags: host.tags.isEmpty ? nil : host.tags,
            authMethod: host.authMethod.rawValue,
            sshConfigAlias: host.sshConfigAlias,
            notes: host.notes)
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "MyTerminal-hosts-\(formatter.string(from: date)).json"
    }

    // MARK: - 가져오기

    /// 파일을 읽어 호스트로 바꾼다. 주소가 없는 항목은 건너뛴다.
    static func decode(_ data: Data) throws -> [SSHHost] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 형식 표시부터 확인해 다른 JSON 파일을 잘못 고른 경우를 알려 준다.
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw ImportError.invalidJSON }
        guard header.format == format else { throw ImportError.notHostFile }
        if let version = header.version, version > currentVersion { throw ImportError.unsupportedVersion(version) }

        guard let file = try? decoder.decode(File.self, from: data) else { throw ImportError.invalidJSON }
        let hosts = file.hosts.compactMap(host)
        guard !hosts.isEmpty else { throw ImportError.empty }
        return hosts
    }

    static func host(_ entry: Entry) -> SSHHost? {
        let hostname = entry.hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty || entry.sshConfigAlias != nil else { return nil }
        var host = SSHHost()
        if let id = entry.id { host.id = id }
        host.name = entry.name ?? ""
        host.hostname = hostname.isEmpty ? entry.sshConfigAlias! : hostname
        host.port = entry.port.flatMap { (1...65535).contains($0) ? $0 : nil }
        host.user = entry.user
        host.identityFile = entry.identityFile
        host.jumpHost = entry.jumpHost
        host.jumpHostID = entry.jumpHostID
        host.remoteCommand = entry.remoteCommand
        host.group = entry.group
        host.tags = entry.tags ?? []
        host.authMethod = entry.authMethod.flatMap(SSHHost.AuthMethod.init(rawValue:)) ?? .auto
        host.sshConfigAlias = entry.sshConfigAlias
        host.notes = entry.notes
        return host
    }

    // MARK: - 중복 처리

    /// 이미 있는 호스트를 어떻게 할지
    enum DuplicatePolicy: String, CaseIterable, Identifiable {
        case skip, overwrite, keepBoth
        var id: String { rawValue }
        var title: String {
            switch self {
            case .skip: "건너뛰기"
            case .overwrite: "덮어쓰기"
            case .keepBoth: "복사본으로 추가"
            }
        }
    }

    struct Item: Identifiable {
        var incoming: SSHHost
        /// 같은 호스트로 보이는 기존 항목
        var existing: SSHHost?
        var id: UUID { incoming.id }
    }

    /// 들어온 호스트마다 기존 호스트와 짝을 찾는다. 같은 id 이거나, 접속 대상(주소·사용자·포트·별칭)이 같으면 같은 호스트로 본다.
    static func plan(incoming: [SSHHost], existing: [SSHHost]) -> [Item] {
        incoming.map { host in
            let match = existing.first { $0.id == host.id } ?? existing.first { key($0) == key(host) }
            return Item(incoming: host, existing: match)
        }
    }

    /// 가져오기 결과: 새로 넣을 것, 고칠 것
    static func resolve(_ items: [Item], policy: DuplicatePolicy) -> (insert: [SSHHost], update: [SSHHost]) {
        var insert: [SSHHost] = []
        var update: [SSHHost] = []
        for item in items {
            guard let existing = item.existing else {
                insert.append(item.incoming)
                continue
            }
            switch policy {
            case .skip:
                continue
            case .overwrite:
                // 기존 id 를 유지해 저장된 비밀번호·최근 접속 기록을 그대로 둔다.
                var host = item.incoming
                host.id = existing.id
                host.lastConnectedAt = existing.lastConnectedAt
                host.createdAt = existing.createdAt
                update.append(host)
            case .keepBoth:
                var host = item.incoming
                host.id = UUID()
                host.name = host.displayName + " (가져옴)"
                insert.append(host)
            }
        }
        return (insert, update)
    }

    private static func key(_ host: SSHHost) -> String {
        [host.sshConfigAlias ?? "", host.hostname.lowercased(), host.user ?? "", String(host.port ?? 22)]
            .joined(separator: "\u{1F}")
    }
}
