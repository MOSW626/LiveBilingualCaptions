import Foundation
import Security

/// API 키 보관소. UserDefaults·소스코드·환경변수에 키를 두지 않는다.
public enum KeychainStore {
    public static let apiKeyAccount = "anthropic.api-key"
    private static let service = "local.codex.LiveBilingualCaptions"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 갱신을 먼저 시도하고, 항목이 없을 때만 새로 추가한다.
    /// 지우고-다시-넣는 방식은 add가 실패하면 기존 키를 통째로 잃는다 — 그래서 쓰지 않는다.
    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func read(account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
