import Foundation
import Security

public final class KeychainStorage {
    public static let shared = KeychainStorage()
    private let serviceName = "com.don.Donby"
    private init() {}

    public func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func load(key: String) -> Data? {
        let scopedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(scopedQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        result = nil
        let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }

    public func delete(key: String) {
        let scopedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(scopedQuery as CFDictionary)

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
