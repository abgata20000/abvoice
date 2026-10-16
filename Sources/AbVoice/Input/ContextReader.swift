import AppKit
import ApplicationServices
import Foundation

/// 挿入先の情報。
struct FocusInfo {
    /// ⚠️ パスワードフィールド。true のときは読み取りも挿入も行わない。
    var isSecureField = false
    /// カーソル直前のテキスト（最大 300 文字）。
    var contextSnippet: String?
    var appName: String?
    var appBundleID: String?
}

/// フォーカス中の UI 要素から、アプリ名とカーソル前のテキストを取る。
///
/// ⚠️⚠️ `kAXSecureTextFieldSubrole` を検出したら、読み取りも挿入も即座に中断する。
enum ContextReader {
    static let snippetLimit = 300

    /// - Parameter includeSnippet: false なら文脈テキストを読まない（設定でコンテキスト送信 OFF のとき）。
    ///   ⚠️ false でもパスワードフィールドの判定は必ず行う。
    static func read(includeSnippet: Bool) -> FocusInfo {
        var info = FocusInfo()
        if let app = NSWorkspace.shared.frontmostApplication {
            info.appName = app.localizedName
            info.appBundleID = app.bundleIdentifier
        }

        guard Permissions.isAccessibilityTrusted else { return info }
        guard let element = focusedElement() else { return info }

        if isSecure(element) {
            info.isSecureField = true
            return info
        }
        guard includeSnippet else { return info }

        info.contextSnippet = textBeforeCursor(in: element)
        return info
    }

    // MARK: 内部

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return copyElement(system, kAXFocusedUIElementAttribute)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        if let subrole = copyString(element, kAXSubroleAttribute),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        if let role = copyString(element, kAXRoleAttribute), role == "AXSecureTextField" {
            return true
        }
        return false
    }

    private static func textBeforeCursor(in element: AXUIElement) -> String? {
        guard let value = copyString(element, kAXValueAttribute), !value.isEmpty else { return nil }

        // カーソル位置（UTF-16 オフセット）。取れないときは末尾扱い。
        var location = -1
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
           let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) {
                location = range.location
            }
        }

        let units = Array(value.utf16)
        let cursor = location < 0 ? units.count : min(max(0, location), units.count)
        let start = max(0, cursor - snippetLimit)
        let snippet = String(decoding: units[start..<cursor], as: UTF16.self)
        return snippet.isEmpty ? nil : snippet
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}
