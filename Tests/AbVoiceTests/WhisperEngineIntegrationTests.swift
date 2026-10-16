import XCTest
@testable import AbVoiceLocal

/// 実際のモデルを使う結合テスト。モデル（数百 MB）と音声が要るので、普段は飛ばす。
///
/// 走らせるとき:
///   ABVOICE_TEST_MODELS=<取得済みモデルの downloadBase> \
///   ABVOICE_TEST_AUDIO=<16kHz / mono / 16bit の WAV を置いたフォルダ> swift test --filter WhisperEngineIntegrationTests
///
/// 音声フォルダに置くファイル:
///   short.wav    … 3 秒以下の日本語（「明日の会議は十時からです。」）
///   names.wav    … 製品名を含む日本語（「クロードコードとカーソルと…」）
///   silence.wav  … 無音
///   long.wav     … 30 秒を超える日本語（途中に「固有名詞」を含む）
final class WhisperEngineIntegrationTests: XCTestCase {
    private static let variant = "large-v3-v20240930_626MB"
    private let engine = WhisperEngine()

    private func environment() throws -> (models: URL, audio: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["ABVOICE_TEST_MODELS"], let audio = env["ABVOICE_TEST_AUDIO"] else {
            throw XCTSkip("ABVOICE_TEST_MODELS と ABVOICE_TEST_AUDIO を指定したときだけ走る")
        }
        return (URL(fileURLWithPath: models, isDirectory: true), URL(fileURLWithPath: audio, isDirectory: true))
    }

    private func loadEngine() async throws -> URL {
        let (models, audio) = try environment()
        let folder = models
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(Self.variant)", isDirectory: true)
        try await engine.load(variant: Self.variant, modelFolder: folder, downloadBase: models)
        return audio
    }

    private func wav(_ name: String, in audio: URL) throws -> (data: Data, duration: TimeInterval) {
        let data = try Data(contentsOf: audio.appendingPathComponent(name))
        return (data, Double(data.count - 44) / 2 / 16_000)
    }

    func test短い日本語を文字起こしできて日本語確率が高い() async throws {
        let audio = try await loadEngine()
        let (data, duration) = try wav("short.wav", in: audio)

        let result = try await engine.transcribe(wav: data, prompt: "", duration: duration, checkLanguage: true)

        XCTAssertTrue(result.text.contains("会議"), result.text)
        XCTAssertGreaterThan(try XCTUnwrap(result.japaneseProbability), 0.9)
    }

    /// ⚠️ プロンプトを渡すと結果が空になる不具合（フィルタで回避）が戻っていないこと。
    func testプロンプトを渡しても空にならず表記が効く() async throws {
        let audio = try await loadEngine()
        let (data, duration) = try wav("names.wav", in: audio)

        let plain = try await engine.transcribe(wav: data, prompt: "", duration: duration, checkLanguage: false)
        let prompted = try await engine.transcribe(
            wav: data, prompt: "Claude Code、Cursor、TypeScript", duration: duration, checkLanguage: false
        )

        XCTAssertFalse(plain.text.isEmpty)
        XCTAssertFalse(prompted.text.isEmpty, "プロンプトを渡すと空になる不具合が戻っている")
        // ⚠️ どの語が効くかは、渡す語の組み合わせで変わる（3 語だと「Claude Code」は「Cloud Code」になった）。
        //    ここでは「プロンプトなしではカタカナだった語が、渡した表記に変わる」ことだけを見る。
        XCTAssertFalse(plain.text.contains("Cursor"), plain.text)
        XCTAssertTrue(prompted.text.contains("Cursor"), prompted.text)
    }

    func test無音は文字起こしせず空を返す() async throws {
        let audio = try await loadEngine()
        let (data, duration) = try wav("silence.wav", in: audio)

        let result = try await engine.transcribe(
            wav: data, prompt: "Claude Code、Cursor", duration: duration, checkLanguage: true
        )

        XCTAssertEqual(result.text, "")
        XCTAssertLessThan(try XCTUnwrap(result.japaneseProbability), HallucinationFilter.japaneseThreshold)
    }

    /// ⚠️ 30 秒の区切りで言葉が落ちないこと（タイムスタンプありに切り替わっていること）。
    func test30秒を超える録音でも区切りで言葉が落ちない() async throws {
        let audio = try await loadEngine()
        let (data, duration) = try wav("long.wav", in: audio)
        XCTAssertGreaterThan(duration, 30)

        let result = try await engine.transcribe(wav: data, prompt: "", duration: duration, checkLanguage: true)

        XCTAssertTrue(result.text.contains("固有名詞"), result.text)
        XCTAssertFalse(result.text.contains("<|"), "特殊トークンが本文に残っている: \(result.text)")
        XCTAssertNil(result.japaneseProbability, "長い録音では言語を調べない")
    }
}
