import CoreML
import Foundation
import WhisperKit

enum WhisperEngineError: LocalizedError {
    case notLoaded
    case badAudio

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "文字起こしモデルがまだ読み込まれていません"
        case .badAudio: return "録音データを読めませんでした"
        }
    }
}

/// プロンプト（辞書の語）の直後、最初に選ぶ 1 トークンだけ、終了トークンを選ばせない。
///
/// ⚠️ 標準モデルは、プロンプトを渡すと直後にいきなり終了トークンを出して結果が空になる
///    （実測で 10 本中 6 本）。先頭トークンのしきい値・やり直し回数・タイムスタンプ・`suppressBlank` の
///    どれを変えても直らず、効いたのはこのフィルタだけだった。
/// ⚠️ プロンプトを渡さないときは付けない。無音まで無理に何か喋らせることになるため。
private final class NoImmediateEndFilter: LogitsFiltering {
    private let endToken: Int
    /// 文字起こしの本文が始まる直前のトークン（タイムスタンプなしの印、または最初のタイムスタンプ）。
    private let lastPrefillToken: Int

    init(endToken: Int, lastPrefillToken: Int) {
        self.endToken = endToken
        self.lastPrefillToken = lastPrefillToken
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard tokens.last == lastPrefillToken else { return logits }
        logits[[0, 0, endToken as NSNumber]] = NSNumber(value: -Float.infinity)
        return logits
    }
}

/// アプリに内蔵した文字起こし（WhisperKit）。モデルをメモリに載せたまま持ち、録音を文字にする。
///
/// ⚠️ 計算ユニットは WhisperKit の既定（ANE）のまま使う。GPU を指定すると圧縮版のモデルでは
///    メモリを 3GB 使い、1 本に 20 秒以上かかった（実測）。
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var kit: WhisperKit?
    private(set) var loadedVariant: String?

    var isLoaded: Bool { kit != nil }

    /// これより長い録音は、タイムスタンプありで文字起こしする。
    /// ⚠️ WhisperKit は 30 秒ごとに区切って処理する。タイムスタンプなしだと区切りの位置で
    ///    言葉が落ちる（実測: 55 秒の録音で、区切りにかかった 1 文の前半が消えた）。
    ///    短い録音はタイムスタンプなしの方が速いので、長いときだけ切り替える。
    private static let timestampThresholdSeconds: TimeInterval = 25

    /// 言語の判定をする録音の長さの上限。`HallucinationFilter.shortRecordingSeconds` と揃える。
    private static let languageCheckSeconds: TimeInterval = 3

    // MARK: 読み込み

    /// モデルをメモリに載せる。
    ///
    /// ⚠️ 取得した直後の 1 回目は、Core ML がこの Mac 向けに最適化するので分単位でかかる
    ///    （実測で標準 80〜184 秒 / 軽量 25〜46 秒）。2 回目以降は 1 秒前後。
    ///    最適化の結果は OS が持つキャッシュで、OS の更新後などに消えることがある。
    /// ⚠️ `download: false` で読み込む。取得済みかの問い合わせだけで 4 秒かかるうえ、
    ///    オフラインで起動できなくなる。
    func load(variant: String, modelFolder: URL, downloadBase: URL) async throws {
        unload()
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        // 最初の 1 本は遅い（実測で 1〜5 秒）。ここで短い無音を通しておく。
        _ = try? await loaded.transcribe(
            audioArray: [Float](repeating: 0, count: 16_000),
            decodeOptions: DecodingOptions(language: "ja", temperatureFallbackCount: 0, withoutTimestamps: true)
        )
        kit = loaded
        loadedVariant = variant
    }

    func unload() {
        kit = nil
        loadedVariant = nil
    }

    // MARK: 文字起こし

    /// - Parameters:
    ///   - wav: 16kHz / mono / 16bit の WAV。
    ///   - prompt: 辞書の語。空なら渡さない。⚠️ 語数に比例して遅くなる（実測で 9 語につき約 0.5 秒）。
    ///   - checkLanguage: 短い録音のとき、先に「日本語か」を調べるか。
    /// - Returns: 日本語でないと判定した短い録音は、文字起こしせずに空のテキストを返す。
    func transcribe(
        wav: Data, prompt: String, duration: TimeInterval, checkLanguage: Bool
    ) async throws -> (text: String, japaneseProbability: Double?) {
        guard let kit, let tokenizer = kit.tokenizer else { throw WhisperEngineError.notLoaded }
        let samples = try Self.samples(fromWav: wav)

        // ⚠️ 言語の判定はエンコーダをもう 1 回回すので 0.7〜1.0 秒かかる。毎回は調べない。
        //    判定を使うのは短い録音だけ（長い録音は、確率が低くても実発話として通す約束）。
        var japaneseProbability: Double?
        if checkLanguage, duration <= Self.languageCheckSeconds {
            // WhisperKit 側の関数名の綴り（detectLangauge）はこのとおり。
            if let detected = try? await kit.detectLangauge(audioArray: samples) {
                // 返ってくるのは 1 位の言語とその対数確率だけ。1 位が日本語でなければ 0 として扱う。
                let probability = detected.language == "ja"
                    ? Double(exp(detected.langProbs["ja"] ?? -.infinity)) : 0
                japaneseProbability = probability
                if probability < HallucinationFilter.japaneseThreshold {
                    // ⚠️ 無音にプロンプトを付けて文字起こしすると、辞書の語が崩れた羅列を返してくる。
                    //    日本語でないと分かった時点でやめる。
                    return ("", probability)
                }
            }
        }

        let withoutTimestamps = duration <= Self.timestampThresholdSeconds
        // ⚠️ やり直しは 1 回まで。既定（5 回）のままだと、無音 + プロンプトで温度を上げながら
        //    30 秒以上やり直すことがある（実測）。
        var options = DecodingOptions(
            language: "ja",
            temperatureFallbackCount: 1,
            skipSpecialTokens: true,
            withoutTimestamps: withoutTimestamps
        )
        let promptTokens = prompt.isEmpty ? [] : tokenizer.encode(text: " " + prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        if promptTokens.isEmpty {
            kit.textDecoder.logitsFilters = nil
        } else {
            options.promptTokens = promptTokens
            kit.textDecoder.logitsFilters = [NoImmediateEndFilter(
                endToken: tokenizer.specialTokens.endToken,
                lastPrefillToken: withoutTimestamps
                    ? tokenizer.specialTokens.noTimestampsToken
                    : tokenizer.specialTokens.timeTokenBegin
            )]
        }

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined()
        return (TextNormalizer.joinSegments(text), japaneseProbability)
    }

    /// WAV（`WavEncoder` が作る 44 バイトのヘッダ + 16bit PCM）を、-1〜1 の Float にする。
    private static func samples(fromWav wav: Data) throws -> [Float] {
        let headerSize = 44
        guard wav.count > headerSize else { throw WhisperEngineError.badAudio }
        let pcm = wav.subdata(in: headerSize..<wav.count)
        return pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }
}
