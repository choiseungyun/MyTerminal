import Foundation
import Security

/// 호스트 비밀번호를 macOS Keychain(로그인 키체인)에 저장한다.
/// 데이터베이스에는 비밀번호를 저장하지 않는다.
enum Keychain {
    static let service = "dev.myterminal.host-password"

    @discardableResult
    static func savePassword(_ password: String, hostID: UUID) -> Bool {
        let data = Data(password.utf8)
        var query = baseQuery(hostID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            NSLog("[MyTerminal] Keychain 저장 실패: \(status)")
            return false
        }
        query[kSecValueData] = data
        query[kSecAttrLabel] = "MyTerminal 호스트 비밀번호"
        let added = SecItemAdd(query as CFDictionary, nil)
        if added != errSecSuccess { NSLog("[MyTerminal] Keychain 추가 실패: \(added)") }
        return added == errSecSuccess
    }

    static func password(hostID: UUID) -> String? {
        var query = baseQuery(hostID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(hostID: UUID) -> Bool {
        var query = baseQuery(hostID)
        query[kSecReturnAttributes] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func deletePassword(hostID: UUID) {
        SecItemDelete(baseQuery(hostID) as CFDictionary)
    }

    private static func baseQuery(_ hostID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: hostID.uuidString,
        ]
    }
}
