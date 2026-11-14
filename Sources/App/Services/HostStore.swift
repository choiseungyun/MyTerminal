import Combine
import Foundation
import GRDB

/// 저장된 호스트 목록. 데이터베이스가 바뀌면 `hosts` 가 자동으로 갱신된다.
final class HostStore: ObservableObject {
    static let shared = HostStore(database: .shared)

    @Published private(set) var hosts: [SSHHost] = []

    private let database: AppDatabase
    private var observation: AnyDatabaseCancellable?

    init(database: AppDatabase) {
        self.database = database
        // 다른 곳(예: 다른 창)에서 바뀐 것도 반영되도록 변경을 관찰한다.
        observation = ValueObservation
            .tracking(Self.fetchAll)
            .start(
                in: database.writer,
                scheduling: .immediate,
                onError: { NSLog("[MyTerminal] 호스트 목록 읽기 실패: \($0)") },
                onChange: { [weak self] in self?.hosts = $0 })
    }

    private static func fetchAll(_ db: Database) throws -> [SSHHost] {
        try SSHHost.order(SSHHost.Columns.name.collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
    }

    /// 자기가 쓴 내용은 관찰 알림(비동기)을 기다리지 않고 바로 반영한다.
    private func reload() {
        do {
            hosts = try database.writer.read(Self.fetchAll)
        } catch {
            NSLog("[MyTerminal] 호스트 목록 읽기 실패: \(error)")
        }
    }

    /// 그룹 이름 목록 (편집 화면의 제안용)
    var groups: [String] {
        Array(Set(hosts.compactMap(\.group).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func host(_ id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    func save(_ host: SSHHost) throws {
        var host = host
        host.updatedAt = Date()
        try database.writer.write { db in try host.save(db) }
        reload()
    }

    func delete(_ id: UUID) throws {
        _ = try database.writer.write { db in try SSHHost.deleteOne(db, key: id) }
        Keychain.deletePassword(hostID: id)
        reload()
    }

    func markConnected(_ id: UUID, at date: Date = Date()) {
        do {
            try database.writer.write { db in
                guard var host = try SSHHost.fetchOne(db, key: id) else { return }
                host.lastConnectedAt = date
                try host.update(db)
            }
            reload()
        } catch {
            NSLog("[MyTerminal] 최근 접속 시간 저장 실패: \(error)")
        }
    }

    /// 여러 호스트를 한 번에 저장한다 (ssh config 가져오기).
    func insert(_ newHosts: [SSHHost]) throws {
        try database.writer.write { db in
            for host in newHosts { try host.insert(db) }
        }
        reload()
    }

    /// 파일 가져오기: 새 호스트는 넣고, 기존 호스트는 고친다 (한 번의 트랜잭션).
    func apply(insert newHosts: [SSHHost], update changed: [SSHHost]) throws {
        try database.writer.write { db in
            for host in newHosts { try host.insert(db) }
            for var host in changed {
                host.updatedAt = Date()
                try host.update(db)
            }
        }
        reload()
    }

    /// 지금까지 가져온 ssh config 별칭 (중복 가져오기 방지)
    var importedAliases: Set<String> {
        Set(hosts.compactMap(\.sshConfigAlias))
    }
}
