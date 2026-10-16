import AppKit

/// 解釈済みのコマンドを順に実行し、結果の一文を返す。
@MainActor
enum CommandExecutor {
    /// - Parameter frontmost: 対象を言わなかったときに使う「停止時点で前面にいたアプリ」。
    /// - Returns: インジケータに出す一文（例:「Slack を右半分に」）。
    static func run(_ commands: [WindowCommand], frontmost: NSRunningApplication?) async throws -> String {
        var parts: [String] = []
        for command in commands {
            let app = try await resolve(command, frontmost: frontmost)
            let name = app.localizedName ?? command.target?.name ?? "ウィンドウ"
            var changed = true
            if command.action != .activate {
                changed = try WindowController.perform(command.action, display: command.display, on: app)
            }
            if changed {
                parts.append("\(name) を\(command.phrase)")
            } else {
                parts.append("\(name) はすでに\(command.display?.label ?? "その位置")にあります")
            }
        }
        return parts.joined(separator: " / ")
    }

    private static func resolve(
        _ command: WindowCommand, frontmost: NSRunningApplication?
    ) async throws -> NSRunningApplication {
        guard let target = command.target else {
            // 対象なしの「前に出して」は何を出すのか決まらない。
            guard command.action != .activate, let frontmost else { throw WindowError.noTarget }
            return frontmost
        }

        switch command.action {
        case .hide, .minimize:
            // ⚠️ 隠す・しまうために前面へ出さない。起動もしない。
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first
            else { throw WindowError.notRunning(target.name) }
            return app
        default:
            return try await WindowController.activate(target)
        }
    }
}
