import Foundation
import Security

/// Cookie 存储抽象。
///
/// 生产环境用 KeychainStore；**测试必须注入 InMemoryCookieStore** —
/// 测试进程读取真实钥匙串服务 "com.pureplay.quark" 的条目会触发系统
/// 授权弹窗（重编译后二进制签名变化，ACL 失效必然重新弹窗），后台
/// CLI 无人应答 → SecItemCopyMatching 永久挂起；同时也会读到用户
/// 的真实 Cookie，属于测试污染。
public protocol CookieStoring: AnyObject {
    func save(key: String, data: Data) throws
    func load(key: String) -> Data?
    func delete(key: String)
    func saveCookies(_ cookies: [String: String]) throws
    func loadCookies() -> [String: String]?
    func clearCookies()
}

/// 内存 Cookie 存储 — 单元测试专用，进程结束即消失，不触碰系统钥匙串
///
/// QuarkAPIClient 的并发网络任务会同时 save/clear（checkAuthStatus 与
/// refreshCookies 在不同 Task 上）— 无锁 Dictionary 竞争曾导致
/// objc_msgSend 野指针崩溃（run21 Thread 9）。NSLock 保护全部读写。
public final class InMemoryCookieStore: CookieStoring {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    public init() {}

    public func save(key: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = data
    }
    public func load(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }
    public func delete(key: String) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    public func saveCookies(_ cookies: [String: String]) throws {
        let data = try JSONEncoder().encode(cookies)
        lock.lock(); defer { lock.unlock() }
        store["cookies"] = data
    }
    public func loadCookies() -> [String: String]? {
        lock.lock()
        let data = store["cookies"]
        lock.unlock()
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
    public func clearCookies() {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: "cookies")
    }
}

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

extension KeychainStore: CookieStoring {}
