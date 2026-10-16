import Foundation

/// 喋っていないのに whisper が返す定番フレーズを弾く。
///
/// ⚠️ 音量のしきい値では分けられない。実測で無音の peak は 0.0087 まで上がることがあり、
///    しきい値を上げると短い発話が全滅する（`VoiceCoordinator` に同じ経緯のコメントがある）。
///    代わりに whisper の**言語確率**を使う。無音を渡すと日本語確率が 0.07 まで落ちるのに対し、
///    実発話は 1.5 秒の短文でも 0.99 台に乗る（2026-08-20 実測）。
///    `no_speech_prob` は無音でも 2e-11 を返してくるので判定に使えない。
enum HallucinationFilter {
    /// これを下回ったら「日本語を喋っていない」とみなす。
    /// ⚠️ 単独では使わない。短い録音のときだけ効かせる（judge のコメント参照）。
    static let japaneseThreshold = 0.5

    /// 言語確率での判定を許す録音の長さ。これを超えたら、確率が低くても実発話として通す。
    /// 幻覚が出るのは無音を渡したときで、その録音は短い（実測はいずれも 2 秒未満）。
    static let shortRecordingSeconds: TimeInterval = 3.0

    /// 学習データの YouTube 字幕に由来する定番の締め文句。
    /// ⚠️ 全文一致でしか使わない。部分一致にすると本当にこう喋ったときに消えてしまう。
    static let phrases: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "最後までご視聴いただきありがとうございました",
        "最後までご視聴いただきありがとうございます",
        "ご清聴ありがとうございました",
        "ご清聴ありがとうございます",
        "チャンネル登録よろしくお願いします",
        "チャンネル登録高評価よろしくお願いします",
        "本日はご覧いただきありがとうございました",
        "おやすみなさい",
        "エンディング",
        "字幕視聴ありがとうございました",
    ]

    /// プロンプトエコーとみなす要素数の下限。辞書は 50 語以上あるので、この程度で誤爆しない。
    static let echoMinimumTerms = 8
    /// プロンプトエコーとみなす一致率。実測では本物のエコーが 89.7%、通常の発話は 0%。
    static let echoRatio = 0.7

    enum Verdict: Equatable {
        case ok
        /// 日本語確率が低い。理由に確率を持たせてログに出す。
        case notJapanese(probability: Double)
        /// 定番フレーズと全文一致した。
        case knownPhrase
        /// 認識ヒント（辞書）をそのまま返してきた。一致率を持たせてログに出す。
        case promptEcho(ratio: Double)
    }

    /// - Parameter duration: 録音の長さ（秒）。⚠️ 長さを見ないと実発話まで消える。理由は下のコメント。
    static func judge(
        text: String, japaneseProbability: Double?, prompt: String, duration: TimeInterval
    ) -> Verdict {
        // 定番フレーズと prompt エコーは、長さに関係なく確実に幻覚なので先に弾く。
        if phrases.contains(normalize(text)) {
            return .knownPhrase
        }
        if let ratio = promptEchoRatio(text: text, prompt: prompt), ratio >= echoRatio {
            return .promptEcho(ratio: ratio)
        }

        // ⚠️⚠️ 言語確率は「短い録音」にしか使わない。
        //    当初は確率だけで判定していたが、実発話まで消した（2026-08-20 の実ログ）。
        //
        //      「ご視聴ありがとうございました。」        ja=0.369 ← 幻覚
        //      「あ、あ、あ…質問です質問なんですけど…」 ja=0.264 ← 78 秒の実発話
        //
        //    冒頭の「あー」や言い淀みで確率が落ちるため、幻覚と実発話の範囲が重なる。
        //    長く喋っているものは、確率が低くても捨ててはいけない
        //    （「喋ったのに残らない」が一番の事故）。
        if duration <= shortRecordingSeconds,
           let japaneseProbability, japaneseProbability < japaneseThreshold {
            return .notJapanese(probability: japaneseProbability)
        }

        return .ok
    }

    /// 出力の読点区切りの要素のうち、どれだけが prompt に含まれるか。
    /// 要素が少ないときは nil（「Slack に投稿をお願いします」のような普通の発話を巻き込まないため）。
    ///
    /// ⚠️ 完全一致では駄目。エコーは「ボギー」を「ボギーー」、「プルリクエスト」を「プルリクエストエスト」の
    ///    ように崩して返してくることがある。だから部分文字列の一致率で見る。
    static func promptEchoRatio(text: String, prompt: String) -> Double? {
        guard !prompt.isEmpty else { return nil }
        let items = terms(text)
        guard items.count >= echoMinimumTerms else { return nil }
        let hit = items.filter { prompt.contains($0) }.count
        return Double(hit) / Double(items.count)
    }

    private static func terms(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,。\n \t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 句読点・記号・空白を落として比較する。「ご視聴ありがとうございました。」と素の文を同じ扱いにするため。
    private static func normalize(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "ぁ-んァ-ヶ一-龠々ー")).inverted)
            .joined()
    }
}
