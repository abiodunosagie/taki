import Foundation
import Security

/// Workspace environment variables live in the login Keychain, one generic-password item per
/// variable (service "Taki env <workspace id>", account = variable name). They are injected only
/// into the processes Taki starts for that workspace and are never shown to an AI chat.
enum Keychain {
    static func service(_ workspaceID: UUID) -> String { "Taki env \(workspaceID.uuidString)" }

    static func set(_ value: String, name: String, workspace: UUID) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service(workspace),
                                   kSecAttrAccount as String: name]
        // Update in place first, so a failed write never loses the old value.
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let r = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if r == errSecSuccess { return true }
        guard r == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(name: String, workspace: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service(workspace),
                                kSecAttrAccount as String: name,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(name: String, workspace: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service(workspace),
                                kSecAttrAccount as String: name]
        SecItemDelete(q as CFDictionary)
    }

    static func deleteAll(workspace: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service(workspace)]
        SecItemDelete(q as CFDictionary)
    }
}
