//
//  LMSessionStore.swift
//  LeapmotorLite
//
//  会话持久化（Keychain，仅本机、仅本 App 可读）
//
import Foundation
import Security

final class LMSessionStore {

    private let service = "com.leapmotor.lite.session"
    private let account = "default"

    /// 写入 Keychain。
    ///
    /// 返回是否成功 —— 侧载重签的 App 有可能拿不到 keychain-access-group
    /// （SecItemAdd 返回 errSecMissingEntitlement -34018），
    /// 这时必须让界面知道「没存进去」，否则用户会以为存好了。
    @discardableResult
    func save(_ session: LMSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        // 先删再写
        clear()
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func load() -> LMSession? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let session = try? JSONDecoder().decode(LMSession.self, from: data) else {
            return nil
        }
        return session
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
