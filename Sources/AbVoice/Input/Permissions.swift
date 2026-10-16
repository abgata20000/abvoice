import ApplicationServices
import AppKit

/// アクセシビリティ権限まわり。CGEventTap（ホットキー）と AX API（画面コンテキスト）、
/// Cmd+V の合成のすべてに必要。
enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// システムのダイアログを出して許可を促す。
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// システム設定のアクセシビリティのページを開く。
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
