import Foundation

/// 辞書。この Mac のファイル（`dictionary.json`）だけに保存する。
///
/// ⚠️ `wrong_forms` の置換は **必ず LLM 整形の「後」** に適用する。
///    大きい LLM が固有名詞を別の語に書き換えた実測があり、最後に機械置換で戻すのが最後の砦になる。
@MainActor
final class LocalDictionaryStore: ObservableObject {
    static let shared = LocalDictionaryStore(fileURL: AppPaths.dictionary)

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var lastError: String?
    /// 辞書のファイルを読めなかった。⚠️ この間は編集を保存しない（読めなかったファイルを空の辞書で潰さないため）。
    ///    画面はこれを見て編集のボタンを止める。
    @Published private(set) var isReadOnly = false

    private let fileURL: URL
    /// 置換テーブル。長い誤変換から先に置くため、あらかじめ並べておく。
    private var replacements: [(wrong: String, correct: String)] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: 認識ヒント

    /// 速報（オンデバイス認識）に渡す認識ヒント。
    /// ⚠️ 効くかどうかは未検証。効かなくても確定側（文字起こし + 辞書置換）で直るので実害は小さい。
    var contextualStrings: [String] { terms }

    /// 整形の LLM に「この表記を崩さないで」と伝える語。
    var formatTerms: String { terms.joined(separator: "、") }

    /// 文字起こしに渡す認識ヒント。新しく直した語から `limit` 語まで。
    /// ⚠️ 渡した語数に比例して文字起こしが遅くなるので、上限は呼び出し側が設定から渡す。0 なら空。
    func whisperPrompt(limit: Int) -> String {
        guard limit > 0 else { return "" }
        return entries.sorted { $0.updatedAt > $1.updatedAt }
            .map(\.term).filter { !$0.isEmpty }
            .prefix(limit).joined(separator: "、")
    }

    private var terms: [String] { entries.map(\.term).filter { !$0.isEmpty } }

    // MARK: 置換

    /// 整形の最後の段。`wrong_forms` を `term` に戻す。
    func applyReplacements(to text: String) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }
        var result = text
        for pair in replacements where result.contains(pair.wrong) {
            result = result.replacingOccurrences(of: pair.wrong, with: pair.correct)
        }
        return result
    }

    // MARK: 編集

    func add(term: String, reading: String?, wrongForms: [String]) {
        entries.append(Self.normalized(DictionaryEntry(term: term, reading: reading, wrongForms: wrongForms)))
        commit()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var next = Self.normalized(entry)
        next.updatedAt = Date()
        entries[index] = next
        commit()
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        commit()
    }

    // MARK: 書き出し・読み込み

    func exportData() throws -> Data {
        try Self.encoder.encode(entries)
    }

    /// 人からもらった辞書を取り込む。同じ `term` があれば、もらった側で上書きする。
    /// - Returns: 取り込んだ語数。
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let incoming = try Self.decoder.decode([DictionaryEntry].self, from: data)
            .map(Self.normalized).filter { !$0.term.isEmpty }
        for entry in incoming {
            if let index = entries.firstIndex(where: { $0.term == entry.term }) {
                var merged = entry
                merged.id = entries[index].id
                entries[index] = merged
            } else {
                // ⚠️ もらった辞書の id が手元と重なっても壊れないよう、振り直す。
                var added = entry
                if entries.contains(where: { $0.id == added.id }) { added.id = UUID().uuidString }
                entries.append(added)
            }
        }
        commit()
        return incoming.count
    }

    // MARK: 内部

    private static func normalized(_ entry: DictionaryEntry) -> DictionaryEntry {
        var next = entry
        next.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = entry.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.reading = reading?.isEmpty == false ? reading : nil
        next.wrongForms = entry.wrongForms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return next
    }

    private func commit() {
        entries.sort { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
        rebuildReplacements()
        save()
    }

    private func rebuildReplacements() {
        var pairs: [(wrong: String, correct: String)] = []
        for entry in entries {
            for wrong in entry.wrongForms where !wrong.isEmpty && wrong != entry.term {
                pairs.append((wrong: wrong, correct: entry.term))
            }
        }
        // ⚠️ 長い誤変換から先に置換する（短いものを先に置くと部分一致で壊れる）。
        replacements = pairs.sorted { $0.wrong.count > $1.wrong.count }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = try Self.decoder.decode([DictionaryEntry].self, from: data).map(Self.normalized)
            entries.sort { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
            rebuildReplacements()
        } catch {
            // ⚠️ 読めなかったファイルを空の辞書で上書きしない（手で直せば戻せるように残す）。
            isReadOnly = true
            lastError = "辞書のファイルを読めないため、編集を保存できません。ファイルを直すか消してから起動し直してください: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard !isReadOnly else { return }
        do {
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "辞書を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
