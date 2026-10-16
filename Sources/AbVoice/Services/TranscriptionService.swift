import Foundation

struct TranscriptionConfig {
    var engine: TranscriptionEngine
    /// 辞書から作った認識ヒント。空なら渡さない。
    var whisperPrompt: String
    /// 短い録音のとき、先に「日本語か」を調べるか。
    /// ⚠️ 音声コマンドでは調べない。「Slack」のような英単語だけの発話が巻き込まれるうえ、
    ///    調べるだけで 0.7〜1.0 秒かかる。
    var checkLanguage = true
    var openAITranscribeModel: String
    var openAIKey: String?
}

struct TranscriptionResult {
    var text: String
    /// 履歴に残す `engine`。`local` / `openai` のどちらか。
    var engine: String
    /// 「日本語である確率」。ハルシネーションの判定に使う。
    /// ⚠️ OpenAI のときは取れないので nil。この Mac の中でも、短い録音のときしか調べない。
    var japaneseProbability: Double?
}

enum TranscriptionError: LocalizedError {
    case localFailed(String)
    case openAIFailed(remote: String, local: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .localFailed(let reason):
            return "文字起こしに失敗しました（\(reason)）"
        case .openAIFailed(let remote, let local):
            return "文字起こしに失敗しました（OpenAI: \(remote) / この Mac: \(local)）"
        case .emptyResult:
            return "文字起こしの結果が空でした。"
        }
    }
}

/// 文字起こし。設定で選んだエンジンを使う。
///
/// ⚠️⚠️ `local` を選んだ人の音声が、失敗をきっかけに黙って外へ出ることがあってはならない。
///    `local` は失敗したらそのまま失敗させる。クラウドには落とさない。
///    逆向き（`openai` が届かなかったとき、この Mac の中に落とす）だけを残す。
/// ⚠️ リトライで粘らない。
actor TranscriptionService {
    static let shared = TranscriptionService()

    /// 直近の成否。状態の表示に使う（ポーリングはしない。最後の結果を出すだけ）。
    private(set) var lastLocalOK: Bool?
    private(set) var lastRemoteOK: Bool?

    // MARK: 本体

    func transcribe(wav: Data, duration: TimeInterval, config: TranscriptionConfig) async throws -> TranscriptionResult {
        switch config.engine {
        case .local:
            do {
                let local = try await transcribeLocal(wav: wav, duration: duration, config: config)
                lastLocalOK = true
                return TranscriptionResult(text: local.text, engine: "local", japaneseProbability: local.japaneseProbability)
            } catch {
                lastLocalOK = false
                throw TranscriptionError.localFailed(error.localizedDescription)
            }

        case .openai:
            let remoteError: String
            do {
                let text = try await transcribeOpenAI(wav: wav, timeout: max(10.0, duration * 0.6), config: config)
                lastRemoteOK = true
                // ⚠️ gpt-4o-transcribe は言語確率を返さない。
                //    ハルシネーション判定は定番フレーズとプロンプトエコーの照合だけが効く。
                return TranscriptionResult(text: text, engine: "openai", japaneseProbability: nil)
            } catch {
                lastRemoteOK = false
                remoteError = error.localizedDescription
            }

            // ⚠️ 黙って切り替えない。理由を必ず残す。
            Task { @MainActor in
                Notifier.shared.warn("OpenAI の文字起こしに失敗したので、この Mac の中で文字起こしします: \(remoteError)")
            }
            do {
                let local = try await transcribeLocal(wav: wav, duration: duration, config: config)
                lastLocalOK = true
                return TranscriptionResult(text: local.text, engine: "local", japaneseProbability: local.japaneseProbability)
            } catch {
                lastLocalOK = false
                throw TranscriptionError.openAIFailed(remote: remoteError, local: error.localizedDescription)
            }
        }
    }

    // MARK: この Mac の中

    private func transcribeLocal(
        wav: Data, duration: TimeInterval, config: TranscriptionConfig
    ) async throws -> (text: String, japaneseProbability: Double?) {
        guard await WhisperEngine.shared.isLoaded else {
            // 取得中・準備中など、いまの状態をそのまま理由として返す。
            throw LocalEngineNotReady(reason: await MainActor.run { ModelManager.shared.statusText })
        }
        return try await WhisperEngine.shared.transcribe(
            wav: wav, prompt: config.whisperPrompt, duration: duration, checkLanguage: config.checkLanguage
        )
    }

    private struct LocalEngineNotReady: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    // MARK: OpenAI（本人が選んだときだけ。音声が送られ、課金される）

    private func transcribeOpenAI(wav: Data, timeout: TimeInterval, config: TranscriptionConfig) async throws -> String {
        guard let key = config.openAIKey, !key.isEmpty else {
            throw HTTPError.notConfigured("OpenAI API キー")
        }
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw HTTPError.badURL
        }

        var body = MultipartBody()
        body.append(name: "file", fileName: "audio.wav", mimeType: "audio/wav", fileData: wav)
        body.append(name: "model", value: config.openAITranscribeModel)
        // ⚠️ 言語を指定しないと「あいうえお」が "I ueo" のようにローマ字化される（実測）。
        body.append(name: "language", value: "ja")
        body.append(name: "response_format", value: "json")
        if !config.whisperPrompt.isEmpty {
            body.append(name: "prompt", value: config.whisperPrompt)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalized()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = json["text"] as? String else {
            throw HTTPError.decoding("text がありません")
        }
        // ⚠️ 末尾に改行が付く。加えてセグメント境界の改行が単語の途中に入るので畳む。
        return TextNormalizer.joinSegments(text)
    }
}
