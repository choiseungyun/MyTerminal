import Foundation
import GRDB

/// 앱 데이터베이스 (SQLite, GRDB)
///
/// 위치: ~/Library/Application Support/MyTerminal/myterminal.sqlite
/// 테이블을 바꿀 때는 기존 마이그레이션을 고치지 말고 새 마이그레이션을 추가한다.
final class AppDatabase {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 앱이 쓰는 데이터베이스. 열 수 없으면 메모리 데이터베이스로 대신한다 (앱은 계속 동작).
    static let shared: AppDatabase = {
        do {
            let folder = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MyTerminal", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: folder.appendingPathComponent("myterminal.sqlite").path)
            return try AppDatabase(queue)
        } catch {
            NSLog("[MyTerminal] 데이터베이스 열기 실패, 메모리 데이터베이스 사용: \(error)")
            return try! AppDatabase.inMemory()
        }
    }()

    /// 테스트용 메모리 데이터베이스
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1: host") { db in
            try db.create(table: SSHHost.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().defaults(to: "")
                t.column("hostname", .text).notNull()
                t.column("port", .integer)
                t.column("user", .text)
                t.column("identityFile", .text)
                t.column("jumpHost", .text)
                t.column("groupName", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")   // JSON 배열
                t.column("authMethod", .text).notNull().defaults(to: SSHHost.AuthMethod.auto.rawValue)
                t.column("sshConfigAlias", .text)
                t.column("notes", .text)
                t.column("lastConnectedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2: host jump/remote command") { db in
            try db.alter(table: SSHHost.databaseTableName) { t in
                t.add(column: "jumpHostID", .blob)
                t.add(column: "remoteCommand", .text)
            }
        }

        migrator.registerMigration("v3: connection history") { db in
            try db.create(table: ConnectionRecord.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("hostID", .blob)
                t.column("title", .text).notNull()
                t.column("user", .text)
                t.column("arguments", .text).notNull().defaults(to: "[]")   // JSON 배열
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("localUser", .text).notNull()
                t.column("localMachine", .text).notNull()
            }
        }

        return migrator
    }
}
