import Foundation

/// ローカルに置くファイルの場所。
/// ~/Library/Application Support/jp.abgata.abvoice.local/ 配下にまとめる。
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("jp.abgata.abvoice.local", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 文字起こしモデルの置き場所。⚠️ アプリには同梱せず、初回に取得してここへ置く。
    static let models: URL = {
        let dir = root.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 辞書（1 ファイルの JSON）。
    static let dictionary = root.appendingPathComponent("dictionary.json")

    /// 履歴（1 行 1 件の JSON Lines）。
    static let history = root.appendingPathComponent("history.jsonl")

    /// 音声コマンド用のアプリの別名表。
    static let appAliases = root.appendingPathComponent("app-aliases.json")
}
