import Foundation

/// 履歴。この Mac のファイル（`history.jsonl`・1 行 1 件）だけに保存する。
///
/// ⚠️ 音声は保存しない。残るのはテキストと所要時間などの数字だけ。
/// ⚠️ 「履歴を残さない」がオンのときは 1 件も書かない（判断は呼び出し側が `append` の前で行う）。
@MainActor
final class LocalHistoryStore: ObservableObject {
    static let shared = LocalHistoryStore(fileURL: AppPaths.history)

    /// 新しい順。
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: 追記

    func append(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        guard let line = Self.line(for: record) else { return }
        do {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
            lastError = nil
        } catch {
            lastError = "履歴を保存できませんでした: \(error.localizedDescription)"
        }
    }

    // MARK: 検索

    /// 挿入したテキスト・文字起こしそのまま・アプリ名のどれかに含まれるものを返す。空なら全件。
    func search(_ query: String) -> [HistoryRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || $0.rawText.localizedCaseInsensitiveContains(needle)
                || ($0.appName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    // MARK: 削除

    func delete(id: String) {
        records.removeAll { $0.id == id }
        rewrite()
    }

    func deleteAll() {
        records = []
        // ⚠️ 消すのではなく空で書き直す。消し損ねると、次に起動したとき履歴が戻ってきてしまう。
        rewrite()
    }

    /// 保持期間を過ぎた行を落とす。起動時に 1 回呼ぶ。
    /// - Parameter retentionDays: 0 以下なら無期限（何もしない）。
    func prune(retentionDays: Int, now: Date = Date()) {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let kept = records.filter { $0.createdAt >= cutoff }
        guard kept.count != records.count else { return }
        records = kept
        rewrite()
    }

    // MARK: 内部

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        // ⚠️ 1 行壊れていても残りは読む（追記の途中で落ちた最終行などを想定）。
        let loaded = content.split(separator: "\n").compactMap { line -> HistoryRecord? in
            try? Self.decoder.decode(HistoryRecord.self, from: Data(line.utf8))
        }
        records = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// ファイルを古い順に書き直す（追記と同じ並びを保つ）。
    private func rewrite() {
        var data = Data()
        for record in records.reversed() {
            if let line = Self.line(for: record) { data.append(line) }
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "履歴を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private static func line(for record: HistoryRecord) -> Data? {
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// ⚠️ 整形（改行入り）で出さない。1 行 1 件が崩れる。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
