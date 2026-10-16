import Foundation
import Security

/// OpenAI の API キーを Keychain に保管する。
/// UserDefaults には平文で置かない。
enum Keychain {
    static let service = "jp.abgata.abvoice.local"

    enum Item: String {
        case openAIKey = "openai_api_key"

        var label: String {
            switch self {
            case .openAIKey: return "OpenAI API キー"
            }
        }
    }

    static func read(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func write(_ item: Item, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(item) }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        let data = Data(trimmed.utf8)

        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ item: Item) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 画面表示用の伏字。値そのものは UI に出さない。
    static func masked(_ item: Item) -> String {
        guard let value = read(item) else { return "未設定" }
        let tail = value.suffix(4)
        return String(repeating: "•", count: max(8, min(24, value.count - 4))) + tail
    }
}
