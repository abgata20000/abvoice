import AppKit
import CoreGraphics
import Foundation

/// カーソル位置にテキストを入れる。
///
/// 1. クリップボードの中身を退避
/// 2. 挿入テキストを書き込む
/// 3. CGEvent で Cmd+V を合成
/// 4. 200ms 後にクリップボードを復元
///
/// ⚠️ パスワードフィールドでは何もしない。
enum TextInserter {
    enum InsertError: LocalizedError {
        case secureField
        case notTrusted
        case empty

        var errorDescription: String? {
            switch self {
            case .secureField: return "パスワードフィールドのため挿入しませんでした。"
            case .notTrusted: return "アクセシビリティ権限が無いためテキストを挿入できません。"
            case .empty: return "挿入するテキストがありません。"
            }
        }
    }

    private static let vKeyCode: CGKeyCode = 9
    private static let restoreDelay: TimeInterval = 0.2
    /// Unicode 直接入力に回してよい長さの上限（短文限定のフォールバック）。
    private static let unicodeLimit = 400

    @MainActor
    static func insert(_ text: String, method: InsertionMethod) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw InsertError.empty }
        guard Permissions.isAccessibilityTrusted else { throw InsertError.notTrusted }

        // ⚠️ 挿入の直前にもう一度パスワードフィールドを確認する。
        if ContextReader.read(includeSnippet: false).isSecureField {
            throw InsertError.secureField
        }

        if method == .unicode, body.utf16.count <= unicodeLimit {
            typeUnicode(body)
            return
        }
        paste(body)
    }

    // MARK: ペースト

    @MainActor
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, to: pasteboard)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: Unicode 直接入力（ペーストが効かないアプリ向け）

    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        // 1 イベントに詰め込みすぎると取りこぼすアプリがあるので刻む。
        let chunkSize = 16
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            index = end
        }
    }

    // MARK: クリップボードへコピーするだけ（履歴のコピーボタン用）

    @MainActor
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
