import Combine
import Foundation
import GRDB

/// 접속 이력. 터미널 SSH 화면·SFTP 탭이 열릴 때 시작을, 닫힐 때 끝을 기록한다. (로컬 터미널은 기록하지 않음)
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(database: .shared)

    /// 최근 접속이 먼저
    @Published private(set) var records: [ConnectionRecord] = []

    private let database: AppDatabase
    private var observation: AnyDatabaseCancellable?

    init(database: AppDatabase) {
        self.database = database
        observation = ValueObservation
            .tracking(Self.fetchAll)
            .start(
                in: database.writer,
                scheduling: .immediate,
                onError: { NSLog("[MyTerminal] 접속 이력 읽기 실패: \($0)") },
                onChange: { [weak self] in self?.records = $0 })
    }

    private static func fetchAll(_ db: Database) throws -> [ConnectionRecord] {
        try ConnectionRecord.order(ConnectionRecord.Columns.startedAt.desc).fetchAll(db)
    }

    func reload() {
        do {
            records = try database.writer.read(Self.fetchAll)
        } catch {
            NSLog("[MyTerminal] 접속 이력 읽기 실패: \(error)")
        }
    }

    private func write(_ work: (Database) throws -> Void) {
        do {
            try database.writer.write(work)
            reload()
        } catch {
            NSLog("[MyTerminal] 접속 이력 저장 실패: \(error)")
        }
    }

    // MARK: - 기록

    /// 접속 시작을 기록하고 id 를 돌려준다.
    @discardableResult
    func start(_ launch: SSHLaunch, kind: ConnectionRecord.Kind, at date: Date = Date()) -> UUID {
        let record = ConnectionRecord(
            kind: kind,
            hostID: launch.hostID,
            title: launch.title,
            user: launch.user,
            arguments: launch.arguments,
            startedAt: date,
            localUser: ConnectionRecord.currentLocalUser,
            localMachine: ConnectionRecord.currentLocalMachine)
        write { db in try record.insert(db) }
        return record.id
    }

    /// 접속 끝을 기록한다. 이미 끝났으면 그대로 둔다.
    func end(_ id: UUID, at date: Date = Date()) {
        write { db in
            guard var record = try ConnectionRecord.fetchOne(db, key: id), record.endedAt == nil else { return }
            record.endedAt = date
            try record.update(db)
        }
    }

    /// 앱을 끝낼 때: 열려 있는 접속을 모두 끝난 것으로 기록한다.
    func endAllOpen(at date: Date = Date()) {
        write { db in
            try ConnectionRecord
                .filter(ConnectionRecord.Columns.endedAt == nil)
                .updateAll(db, ConnectionRecord.Columns.endedAt.set(to: date))
        }
    }

    /// 앱을 끝낼 때: 화면 목록은 갱신하지 않는다 (종료 감시 스레드에서도 부른다)
    func endAllOpenForExit(at date: Date = Date()) {
        do {
            try database.writer.write { db in
                _ = try ConnectionRecord
                    .filter(ConnectionRecord.Columns.endedAt == nil)
                    .updateAll(db, ConnectionRecord.Columns.endedAt.set(to: date))
            }
        } catch {
            NSLog("[MyTerminal] 접속 이력 저장 실패: \(error)")
        }
    }

    /// 저장하지 않은 접속을 호스트로 저장했을 때: 같은 접속 인자의 기록을 그 호스트에 연결한다.
    func link(arguments: [String], to hostID: UUID) {
        write { db in
            for var record in try ConnectionRecord.filter(ConnectionRecord.Columns.hostID == nil).fetchAll(db)
            where record.arguments == arguments {
                record.hostID = hostID
                try record.update(db)
            }
        }
    }

    func delete(_ ids: Set<UUID>) {
        write { db in _ = try ConnectionRecord.deleteAll(db, keys: Array(ids)) }
    }

    func clear() {
        write { db in _ = try ConnectionRecord.deleteAll(db) }
    }
}
