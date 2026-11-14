import Foundation

/// 번들 ID 변경(dev.myterminal.app → kr.weare.myterminal) 후 처음 실행할 때,
/// 예전 번들 ID 로 저장된 앱 설정(테마·글꼴·패널 폭 등)을 한 번 옮겨 온다.
/// 호스트·접속 이력 데이터베이스와 설정 파일은 번들 ID 와 무관한 폴더라 옮길 필요가 없다.
enum PreferencesMigration {
    static let oldDomain = "dev.myterminal.app"
    static let doneKey = "migration.fromDevMyTerminalApp"
    /// 옮길 설정의 키 접두어 (이 앱이 쓰는 것만)
    static let prefixes = ["terminal.", "hosts.", "filePanel.", "sftp."]

    static func run(
        into defaults: UserDefaults = .standard,
        from oldValues: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldDomain)
    ) {
        guard Bundle.main.bundleIdentifier != oldDomain, !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let oldValues else { return }

        for (key, value) in oldValues where prefixes.contains(where: key.hasPrefix) {
            // 새 번들에서 이미 바꾼 값은 덮어쓰지 않는다
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
    }
}
