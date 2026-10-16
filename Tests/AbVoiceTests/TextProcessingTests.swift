import XCTest
@testable import AbVoiceLocal

/// コピーしてきた純粋関数の回帰テスト。実測に基づく約束（コメントの ⚠️）が崩れていないことを見る。
final class TextProcessingTests: XCTestCase {
    // MARK: FillerRemover

    func testフィラーを落とす() {
        XCTAssertEqual(FillerRemover.remove(from: "えーと、明日は休みです"), "明日は休みです")
        XCTAssertEqual(FillerRemover.remove(from: "今日は、えーと、休みです"), "今日は、休みです")
        XCTAssertEqual(FillerRemover.remove(from: "えーと、あのー、それでいいです"), "それでいいです")
    }

    /// ⚠️ 意味のある語と同形のものは、直後に読点があるときだけ落とす。
    func test意味のある語は壊さない() {
        XCTAssertEqual(FillerRemover.remove(from: "あの人に会った"), "あの人に会った")
        XCTAssertEqual(FillerRemover.remove(from: "なんか買った"), "なんか買った")
        XCTAssertEqual(FillerRemover.remove(from: "その件は了解です"), "その件は了解です")
        XCTAssertEqual(FillerRemover.remove(from: "あの、明日は休みです"), "明日は休みです")
    }

    // MARK: HallucinationFilter

    func test定番の締め文句は長さに関係なく弾く() {
        for duration in [1.0, 60.0] {
            XCTAssertEqual(
                HallucinationFilter.judge(
                    text: "ご視聴ありがとうございました。", japaneseProbability: 0.99, prompt: "", duration: duration
                ),
                .knownPhrase
            )
        }
    }

    /// ⚠️ 全文一致でしか弾かない。本当にそう喋った文を消さないため。
    func test締め文句を含むだけの文は通す() {
        XCTAssertEqual(
            HallucinationFilter.judge(
                text: "昨日の動画は、ご視聴ありがとうございましたで終わっていました。",
                japaneseProbability: nil, prompt: "", duration: 5
            ),
            .ok
        )
    }

    /// ⚠️ 言語確率は短い録音にしか使わない。長く喋ったものは、確率が低くても捨てない。
    func test言語確率は短い録音にだけ効く() {
        XCTAssertEqual(
            HallucinationFilter.judge(text: "こんにちは", japaneseProbability: 0.2, prompt: "", duration: 2),
            .notJapanese(probability: 0.2)
        )
        XCTAssertEqual(
            HallucinationFilter.judge(text: "こんにちは", japaneseProbability: 0.2, prompt: "", duration: 30),
            .ok
        )
        XCTAssertEqual(
            HallucinationFilter.judge(text: "こんにちは", japaneseProbability: nil, prompt: "", duration: 2),
            .ok
        )
        XCTAssertEqual(
            HallucinationFilter.judge(text: "こんにちは", japaneseProbability: 0.99, prompt: "", duration: 2),
            .ok
        )
    }

    func test認識ヒントをそのまま返してきたら弾く() {
        let prompt = "Slack、GitHub、Docker、Cursor、TypeScript、Xcode、Swift、Python、Ruby"
        XCTAssertEqual(
            HallucinationFilter.judge(
                text: "Slack、GitHub、Docker、Cursor、TypeScript、Xcode、Swift、Python",
                japaneseProbability: nil, prompt: prompt, duration: 5
            ),
            .promptEcho(ratio: 1.0)
        )
    }

    /// 辞書の語を 1 つ含むだけの普通の発話は巻き込まない。
    func test辞書の語を含む普通の発話は通す() {
        XCTAssertEqual(
            HallucinationFilter.judge(
                text: "Slack に投稿をお願いします", japaneseProbability: nil,
                prompt: "Slack、GitHub、Docker", duration: 5
            ),
            .ok
        )
    }

    // MARK: SentenceWrapper

    func test文の終わりで改行する() {
        let text = "今日は晴れです。明日は雨です。"
        XCTAssertEqual(SentenceWrapper.wrap(text, mode: .none), text)
        XCTAssertEqual(SentenceWrapper.wrap(text, mode: .sentence), "今日は晴れです。\n明日は雨です。")
        XCTAssertEqual(SentenceWrapper.wrap(text, mode: .paragraph), "今日は晴れです。\n\n明日は雨です。")
    }

    func test閉じ括弧は前の文に含める() {
        XCTAssertEqual(SentenceWrapper.wrap("「行きます。」と言った。", mode: .sentence), "「行きます。」\nと言った。")
    }

    /// 元から改行があった箇所は空行が 1 行入る（それ以上には増えない）。
    func test元からある改行は空行1行までに畳む() {
        XCTAssertEqual(SentenceWrapper.wrap("一行目。\n二行目。", mode: .sentence), "一行目。\n\n二行目。")
        XCTAssertEqual(SentenceWrapper.wrap("一行目。\n\n\n二行目。", mode: .paragraph), "一行目。\n\n二行目。")
    }

    // MARK: TextNormalizer

    /// ⚠️ セグメント境界の改行は単語の途中に来ることがある。
    func testセグメント境界の改行を畳む() {
        XCTAssertEqual(TextNormalizer.joinSegments("リポジトリのバックエ\nンドに実装したい\n"), "リポジトリのバックエンドに実装したい")
        XCTAssertEqual(TextNormalizer.joinSegments("hello\nworld"), "hello world")
        XCTAssertEqual(TextNormalizer.joinSegments("  \n"), "")
    }

    // MARK: Ollama のモデル取得の進捗

    func testOllamaの取得の行を読める() {
        XCTAssertEqual(
            FormatService.pullEvent(fromLine: #"{"status":"pulling abc","total":200,"completed":50}"#),
            .progress(0.25)
        )
        XCTAssertEqual(FormatService.pullEvent(fromLine: #"{"status":"pulling manifest"}"#), .progress(nil))
        XCTAssertEqual(FormatService.pullEvent(fromLine: #"{"status":"success"}"#), .success)
        XCTAssertEqual(
            FormatService.pullEvent(fromLine: #"{"error":"pull model manifest: file does not exist"}"#),
            .failure("pull model manifest: file does not exist")
        )
        XCTAssertNil(FormatService.pullEvent(fromLine: "JSON ではない行"))
    }

    // MARK: 外国語の混入チェック

    func test入力に無かった文字体系が混ざったら名前を返す() {
        XCTAssertEqual(FormatService.foreignScript(in: "안녕하세요", source: "こんにちは"), "ハングル")
        XCTAssertEqual(FormatService.foreignScript(in: "Привет", source: "こんにちは"), "キリル文字")
    }

    /// ⚠️ 本人がその言語の語を喋ったときは弾かない。
    func test入力にもあった文字体系は通す() {
        XCTAssertNil(FormatService.foreignScript(in: "안녕하세요と言いました", source: "안녕하세요って言いました"))
        XCTAssertNil(FormatService.foreignScript(in: "明日の会議は 10 時から。Slack で連絡します。", source: "明日の会議は10時からスラックで連絡します"))
    }
}
