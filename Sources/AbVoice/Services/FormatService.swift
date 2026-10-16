import Foundation

struct FormatConfig {
    var provider: FormatProvider
    var ollamaURL: URL?
    var ollamaTagsURL: URL?
    var model: String
    var openAIModel: String
    var openAIKey: String?
    /// プロンプトに入れる「正しい表記」。辞書の語を並べたもの。
    var terms: String
}

struct FormatResult {
    var text: String
    /// 整形に使ったモデル。`gemma3:4b` / `gpt-4o-mini` / `none`。
    var model: String
}

/// この Mac の Ollama が使えるか。
enum OllamaStatus: Equatable {
    /// まだ調べていない。
    case unknown
    /// 入っていない / 起動していない。
    case notRunning
    /// 動いているが、整形用のモデルが無い。
    case modelMissing
    case ready
}

/// 整形の 2 段目（LLM）。
///
/// ⚠️ 大きいモデル（27B 級以上）は使わない。遅いうえに固有名詞を別の語に書き換える実測がある。
///    既定は `gemma3:4b`。
/// ⚠️ ここが失敗しても挿入は止めない。整形前のテキストをそのまま返す。
/// ⚠️ 選ばれていないプロバイダへ自動で切り替えない。Ollama を選んだ人のテキストが、
///    失敗をきっかけに OpenAI へ送られることがあってはならない。
actor FormatService {
    static let shared = FormatService()

    /// 直近に Ollama での整形が成功した時刻。
    /// ⚠️ Ollama は `keep_alive` が切れるとモデルを降ろす。冷えた状態の初回は実測 13.1 秒かかる
    ///    （温まっていれば 0.88 秒）。冷えている可能性がある 1 回だけタイムアウトを緩める。
    private var lastLocalSuccessAt: Date?
    private let keepAliveWindow: TimeInterval = 25 * 60

    /// 最後に調べた Ollama の状態。`auto` のとき、これが `.ready` なら Ollama を使う。
    private(set) var ollamaStatus: OllamaStatus = .unknown

    /// Ollama があるか、整形用のモデルが入っているかを 1 回調べる。
    /// ⚠️ 定期的には調べない。起動時の 1 回と、設定画面のボタンを押したときだけ。
    @discardableResult
    func detectOllama(config: FormatConfig) async -> OllamaStatus {
        ollamaStatus = await Self.probeOllama(tagsURL: config.ollamaTagsURL, model: config.model)
        return ollamaStatus
    }

    private static func probeOllama(tagsURL: URL?, model: String) async -> OllamaStatus {
        guard let tagsURL else { return .notRunning }
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains(response.httpStatusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return .notRunning }
        // `gemma3:4b` と書いても `gemma3:4b` そのものしか一致させない（タグ違いは別のモデル）。
        // タグを省いた指定（`gemma3`）は Ollama が `:latest` として扱うので、それだけ補う。
        let wanted = model.contains(":") ? model : model + ":latest"
        let names = models.compactMap { $0["name"] as? String }
        return names.contains(wanted) ? .ready : .modelMissing
    }

    // MARK: Ollama のモデル取得

    /// `/api/pull` が 1 行ずつ返してくる JSON の読み取り結果。
    enum PullEvent: Equatable {
        /// 取得中。0〜1。大きさがまだ分からない行（準備中など）は nil。
        case progress(Double?)
        case success
        case failure(String)
    }

    static func pullEvent(fromLine line: String) -> PullEvent? {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let message = json["error"] as? String { return .failure(message) }
        if json["status"] as? String == "success" { return .success }
        guard let total = (json["total"] as? NSNumber)?.doubleValue, total > 0,
              let completed = (json["completed"] as? NSNumber)?.doubleValue else { return .progress(nil) }
        return .progress(min(1, completed / total))
    }

    /// この Mac の Ollama に、整形用のモデルを取得させる。
    /// ⚠️ 取得するのは Ollama 自身（このアプリは頼むだけ）。保存先も Ollama の管理下になる。
    func pullOllamaModel(config: FormatConfig, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = config.ollamaTagsURL?.deletingLastPathComponent().appendingPathComponent("pull") else {
            throw HTTPError.notConfigured("Ollama の URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 取得は数分かかる。行が流れてこない時間（展開・検証）もあるので長めに取る。
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "stream": true])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, nil)
        }
        var succeeded = false
        for try await line in bytes.lines {
            switch Self.pullEvent(fromLine: line) {
            case .progress(let fraction?): onProgress(fraction)
            case .progress(nil), nil: break
            case .success: succeeded = true
            case .failure(let message): throw HTTPError.status(response.httpStatusCode, message)
            }
        }
        // ⚠️ 「success」の行を見ないまま終わったら、途中で切れている。成功扱いにしない。
        guard succeeded else { throw HTTPError.emptyBody }
    }

    /// 設定から、実際に使うプロバイダを決める。`auto` は調べた結果に従う。
    func resolvedProvider(_ config: FormatConfig) -> FormatProvider {
        switch config.provider {
        case .auto: return ollamaStatus == .ready ? .ollama : .none
        case .ollama, .openai, .none: return config.provider
        }
    }

    static let systemPrompt = """
    あなたは日本語の音声入力を整形するアシスタントです。
    入力は音声認識の生テキストです。次の規則に従って書き言葉に整えてください。

    規則:
    - フィラー（えーと / あの / うーん など）と言い淀みを取り除く
    - 言い直しがある場合は、後から言い直した方を採用する
    - 句読点を補い、読みやすい文にする
    - 内容を追加・要約・省略しない。言っていないことを書かない
    - 固有名詞・製品名・専門用語は絶対に書き換えない（知らない語でもそのまま残す）
    - 記号・コード・URL・英単語・数字はそのまま残す
    - 前置き・説明・見出し・箇条書き・引用符を付けない。整形後の本文だけを返す
    - 出力は必ず日本語。翻訳しない。入力に無い言語の文字を書かない
    """

    /// 起動時にモデルを載せておく。プロンプト無しで叩くと Ollama はロードだけして返す。
    /// ⚠️ これは死活監視ではない（定期的には叩かない。起動時の 1 回だけ）。
    func warmUp(config: FormatConfig) async {
        guard resolvedProvider(config) == .ollama, let url = config.ollamaURL else { return }
        let payload: [String: Any] = ["model": config.model, "keep_alive": "30m"]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        if let (_, response) = try? await URLSession.shared.data(for: request),
           (200..<300).contains(response.httpStatusCode) {
            lastLocalSuccessAt = Date()
        }
    }

    func format(_ text: String, duration: TimeInterval, config: FormatConfig) async -> FormatResult {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return FormatResult(text: source, model: "none") }

        let formatted: String
        let model: String
        do {
            switch resolvedProvider(config) {
            case .ollama:
                // 温まっていれば短く、冷えている可能性があるときだけ緩める。
                let isWarm = lastLocalSuccessAt.map { Date().timeIntervalSince($0) < keepAliveWindow } ?? false
                let timeout = isWarm ? max(6.0, duration * 0.8) : max(20.0, duration * 0.8)
                formatted = try await Self.formatWithOllama(source, timeout: timeout, config: config)
                lastLocalSuccessAt = Date()
                model = config.model
            case .openai:
                formatted = try await Self.formatWithOpenAI(source, timeout: max(12.0, duration), config: config)
                model = config.openAIModel
            case .none, .auto:
                return FormatResult(text: source, model: "none")
            }
        } catch {
            Task { @MainActor in
                Notifier.shared.warn("整形に失敗したため整形なしで挿入します: \(error.localizedDescription)")
            }
            // ⚠️ 整形の失敗で挿入を止めない。別のプロバイダにも切り替えない。
            return FormatResult(text: source, model: "none")
        }

        // ⚠️ 小さいモデルは聞き取りにくい入力で他言語に流れることがある。
        //    黙って挿入すると本文が壊れるので、整形前に戻す（挿入は止めない）。
        if let script = Self.foreignScript(in: formatted, source: source) {
            Task { @MainActor in
                Notifier.shared.warn(
                    "整形結果に\(script)が混ざっていたため、整形前のテキストを挿入します: \(formatted.prefix(40))",
                    notify: true
                )
            }
            return FormatResult(text: source, model: "none")
        }
        return FormatResult(text: formatted, model: model)
    }

    private static func userPrompt(_ text: String, terms: String) -> String {
        var prompt = ""
        if !terms.isEmpty {
            prompt += "次の語は正しい表記です。出てきた場合はこの表記のまま残してください:\n\(terms)\n\n"
        }
        prompt += "整形する音声認識テキスト:\n\(text)"
        return prompt
    }

    // MARK: Ollama（この Mac の中）

    private static func formatWithOllama(_ text: String, timeout: TimeInterval, config: FormatConfig) async throws -> String {
        guard let url = config.ollamaURL else { throw HTTPError.notConfigured("Ollama の URL") }

        // 長い発話で途中打ち切りにならないよう入力長から見積もる。
        let numPredict = min(2048, max(512, text.count * 2))
        let payload: [String: Any] = [
            "model": config.model,
            "system": systemPrompt,
            "prompt": userPrompt(text, terms: config.terms),
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0.2, "num_predict": numPredict],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = json["response"] as? String else {
            throw HTTPError.decoding("response がありません")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HTTPError.emptyBody }
        return trimmed
    }

    // MARK: OpenAI（本人が選んだときだけ。テキストが送られ、課金される）

    private static func formatWithOpenAI(_ text: String, timeout: TimeInterval, config: FormatConfig) async throws -> String {
        guard let key = config.openAIKey, !key.isEmpty else {
            throw HTTPError.notConfigured("OpenAI API キー")
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw HTTPError.badURL }

        let payload: [String: Any] = [
            "model": config.openAIModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(text, terms: config.terms)],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw HTTPError.decoding("choices[0].message.content がありません")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HTTPError.emptyBody }
        return trimmed
    }

    // MARK: 外国語の混入チェック

    /// 判定に使う文字体系。⚠️ **漢字（Han）は入れない。** 日本語と中国語で共通なので、
    ///    文字種では切り分けられない（中国語への流れ込みはここでは捕まえられない）。
    private static let watchedScripts: [(name: String, range: ClosedRange<UInt32>)] = [
        ("ハングル", 0x1100...0x11FF), ("ハングル", 0x3130...0x318F), ("ハングル", 0xAC00...0xD7AF),
        ("キリル文字", 0x0400...0x04FF),
        ("ギリシャ文字", 0x0370...0x03FF),
        ("アラビア文字", 0x0600...0x06FF),
        ("ヘブライ文字", 0x0590...0x05FF),
        ("デーヴァナーガリー", 0x0900...0x097F),
        ("タイ文字", 0x0E00...0x0E7F),
    ]

    /// 整形結果に、**入力に無かった**文字体系が混ざっていないか。混ざっていればその名前を返す。
    ///
    /// ⚠️ 「入力に無かった」が要。本人がロシア語の固有名詞を喋ったのに弾いては困るので、
    ///    生テキストに既にその文字体系があれば通す。
    static func foreignScript(in formatted: String, source: String) -> String? {
        let inSource = scripts(in: source)
        for name in scripts(in: formatted) where !inSource.contains(name) {
            return name
        }
        return nil
    }

    private static func scripts(in text: String) -> Set<String> {
        var found: Set<String> = []
        for scalar in text.unicodeScalars {
            for script in watchedScripts where script.range.contains(scalar.value) {
                found.insert(script.name)
            }
        }
        return found
    }
}
