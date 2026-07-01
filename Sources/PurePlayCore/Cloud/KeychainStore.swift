import Foundation
import Security

/// macOS Keychain 封装 — 安全存储夸克网盘 Cookie
public final class KeychainStore {
    private let service: String

    public init(service: String = "com.pureplay.quark") {
        self.service = service
    }

    public func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PurePlayError.ioError("Keychain save failed: \(status)")
        }
    }

    public func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func saveCookies(_ cookies: [String: String]) throws {
        let data = try JSONEncoder().encode(cookies)
        try save(key: "cookies", data: data)
    }

    public func loadCookies() -> [String: String]? {
        guard let data = load(key: "cookies") else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    public func clearCookies() {
        delete(key: "cookies")
    }
}
