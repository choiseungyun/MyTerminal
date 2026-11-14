import XCTest
@testable import MyTerminal

final class PreferencesMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "test.migration.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCopiesOnlyAppKeysOnce() {
        let old: [String: Any] = [
            "terminal.theme": "Dracula",
            "filePanel.width": 420.0,
            "sftp.splitRatio": 0.6,
            "NSWindow Frame main": "0 0 100 100",   // 앱 설정이 아닌 것은 옮기지 않음
        ]
        defaults.set("Nord", forKey: "terminal.fontFamily")
        defaults.set(500.0, forKey: "filePanel.width")   // 새 번들에서 이미 바꾼 값

        PreferencesMigration.run(into: defaults, from: old)
        XCTAssertEqual(defaults.string(forKey: "terminal.theme"), "Dracula")
        XCTAssertEqual(defaults.double(forKey: "sftp.splitRatio"), 0.6)
        XCTAssertEqual(defaults.double(forKey: "filePanel.width"), 500, "이미 있는 값은 덮어쓰지 않음")
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame main"))
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.doneKey))

        // 두 번째 실행은 아무것도 하지 않는다
        defaults.removeObject(forKey: "terminal.theme")
        PreferencesMigration.run(into: defaults, from: old)
        XCTAssertNil(defaults.object(forKey: "terminal.theme"))
    }

    func testNoOldDomainJustMarksDone() {
        PreferencesMigration.run(into: defaults, from: nil)
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.doneKey))
    }
}
