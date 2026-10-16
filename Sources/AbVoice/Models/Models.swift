import Foundation

// MARK: - 辞書

/// 辞書の 1 語。`dictionary.json` にこの形の配列で保存する。
/// ⚠️ キー名は人から辞書をもらったときにそのまま読めるよう、スネークケースで固定する。
struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: String
    /// 正しい表記。
    var term: String
    var reading: String?
    /// この語に直したい誤変換。
    var wrongForms: [String]
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, term, reading
        case wrongForms = "wrong_forms"
        case updatedAt = "updated_at"
    }

    init(id: String = UUID().uuidString, term: String, reading: String? = nil, wrongForms: [String] = [], updatedAt: Date = Date()) {
        self.id = id
        self.term = term
        self.reading = reading
        self.wrongForms = wrongForms
        self.updatedAt = updatedAt
    }

    /// ⚠️ 手で書いた辞書も読めるように、`term` 以外は無くても通す。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        term = try c.decode(String.self, forKey: .term)
        reading = try? c.decodeIfPresent(String.self, forKey: .reading)
        wrongForms = (try? c.decodeIfPresent([String].self, forKey: .wrongForms)) ?? []
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

// MARK: - 履歴

/// 履歴の 1 件。`history.jsonl` に 1 行 1 件で保存する。
/// ⚠️ 音声は持たない（録音は文字起こしが済んだら捨てる）。
struct HistoryRecord: Codable, Identifiable, Hashable {
    var id: String
    var createdAt: Date
    /// 文字起こしそのまま。
    var rawText: String
    /// 整形・辞書置換のあと、実際に挿入したテキスト。
    var text: String
    /// `local` / `openai`
    var engine: String
    /// 整形に使ったモデル。整形しなかったときは `none`。
    var formatModel: String
    var durationMs: Int
    var latencyMs: Int
    var appName: String?
    var appBundleID: String?

    enum CodingKeys: String, CodingKey {
        case id, text, engine
        case createdAt = "created_at"
        case rawText = "raw_text"
        case formatModel = "format_model"
        case durationMs = "duration_ms"
        case latencyMs = "latency_ms"
        case appName = "app_name"
        case appBundleID = "app_bundle_id"
    }

    /// 表示に使うテキスト。整形済みが無ければ生テキスト。
    var displayText: String { text.isEmpty ? rawText : text }
}
