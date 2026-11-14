import Foundation
import GRDB

/// 접속 이력 하나 (언제, 이 Mac 의 누가, 어느 서버에, 얼마나)
struct ConnectionRecord: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        /// 터미널 SSH 접속
        case ssh
        /// SFTP 탭 접속
        case sftp
    }

    var id: UUID = UUID()
    var kind: Kind
    /// 저장된 호스트로 접속했으면 그 id
    var hostID: UUID?
    /// 접속할 때의 이름 (호스트가 나중에 지워지거나 이름이 바뀌어도 기록은 남는다)
    var title: String
    /// 서버 사용자
    var user: String?
    /// 다시 접속할 때 쓰는 ssh 인자
    var arguments: [String]
    var startedAt: Date
    /// 끝난 시각. nil = 접속 중이거나 앱이 비정상 종료되어 모름
    var endedAt: Date?
    /// 이 Mac 의 사용자·컴퓨터 이름
    var localUser: String
    var localMachine: String

    /// 카드·표 부제목: "ssh, deploy" / "sftp, deploy"
    var subtitle: String {
        [kind.rawValue, user].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// 다시 접속할 빠른 연결 대상 (저장된 호스트가 없을 때)
    var quickTarget: QuickConnectTarget? {
        QuickConnectTarget(arguments.map(SSHCommand.shellQuote).joined(separator: " "))
    }

    static var currentLocalUser: String { NSUserName() }
    static var currentLocalMachine: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}

extension ConnectionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "connection"

    enum Columns {
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
        static let hostID = Column(CodingKeys.hostID)
    }
}
