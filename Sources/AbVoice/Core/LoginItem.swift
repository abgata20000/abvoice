import AppKit
import ServiceManagement

/// ログイン時の自動起動。
///
/// ⚠️ System Events 経由でログイン項目を足す方法は採らない。
///    設定画面に出ないので後から分からなくなるうえ、自動化の権限承認が要るため。
///    `SMAppService.mainApp` ならアプリ自身が登録でき、システム設定側にも並ぶ。
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// トグルでは扱えない状態か。承認待ちや実体が見つからないときは説明を出す必要がある。
    static var needsAttention: Bool {
        status == .requiresApproval || status == .notFound
    }

    static var statusMessage: String? {
        switch status {
        case .requiresApproval:
            return "システム設定の「ログイン項目」で AbVoice を許可してください。"
        case .notFound:
            return "アプリの実体が見つかりません。/Applications に置いたうえで登録し直してください。"
        default:
            return nil
        }
    }

    /// - Returns: 変更後に読み直した状態。
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
