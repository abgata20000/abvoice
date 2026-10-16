import Foundation

/// 聞き取った文をパターン照合でコマンドにする（1 段目。0ms）。
///
/// ⚠️ 純粋関数にしておく。照合の候補（別名表・起動中アプリ）は引数でもらう。
/// ⚠️ 解釈に自信が無いものは空を返して LLM に回す。当て推量で実行しない。
enum CommandParser {
    /// 「この言葉が出たらこのアプリ」の 1 件。
    struct Candidate: Equatable {
        var phrase: String
        var target: AppTarget
    }

    /// キーワードは実際の whisper の出力を見て増やす。最初から網羅しようとしない。
    /// ⚠️ 「全面」単独は入れない。「前面」の聞き間違いと区別できない（2026-10-14 の実ログ）。
    static let keywords: [(action: WindowCommand.Action, words: [String])] = [
        (.maximize, ["最大化", "最大に", "いっぱいに", "全体に", "大きくして", "全面表示", "全画面", "画面全体"]),
        (.leftHalf, ["左半分", "左側", "左に寄せ", "左に置", "左にして"]),
        (.rightHalf, ["右半分", "右側", "右に寄せ", "右に置", "右にして"]),
        (.topHalf, ["上半分", "上側"]),
        (.bottomHalf, ["下半分", "下側"]),
        (.topLeftQuarter, ["左上"]),
        (.topRightQuarter, ["右上"]),
        (.bottomLeftQuarter, ["左下"]),
        (.bottomRightQuarter, ["右下"]),
        (.center, ["真ん中", "まんなか", "中央", "センター"]),
        (.restore, ["元に戻", "もとに戻", "元のサイズ", "元の大きさ", "元の位置"]),
        (.minimize, ["最小化", "しまって", "しまう"]),
        (.hide, ["隠して", "隠す", "かくして", "非表示"]),
        (.activate, ["前に", "最前面", "前面", "開いて", "ひらいて", "表示して", "切り替え", "切替", "出して", "見せて", "持ってきて"]),
    ]

    /// 「右のモニターに」「隣の画面に」。操作の語より先に抜き出す
    /// （「真ん中のモニター」の「真ん中」を「中央に置く」と取り違えないため）。
    private static let displayPattern = try? NSRegularExpression(
        pattern: "(右|左|真ん中|まんなか|中央|メイン|隣|となり|別|次|他|ほか)側?の?(画面|ディスプレイ|モニタ)"
    )

    /// 対象を言っていないのと同じ扱いにする語（= 前面のウィンドウ）。
    private static let pronouns = [
        "このウィンドウ", "今のウィンドウ", "いまのウィンドウ", "このアプリ", "今のアプリ",
        "ウィンドウ", "これ", "それ", "この", "今の", "いまの",
    ]

    /// 操作の語のほかに、これより長い文が残っていたら自信が無いものとして LLM に回す。
    /// （「スラック右半分にして」の「スラック」を見落として前面のウィンドウを動かさないため）
    private static let maxExtraLength = 6

    enum Analysis: Equatable {
        /// そのまま実行できる。
        case commands([WindowCommand])
        /// 操作は分かったが、アプリの呼び名（「スラック」）が候補に無い。
        /// ⚠️ 操作まで LLM に解釈させ直さない。小さいモデルは位置の指示を取り違える
        ///    （「Chrome を右上にして」を「右の画面の左半分」にした実ログがある）。名前だけを聞く。
        case needsTarget(WindowCommand, spokenName: String)
        /// 解釈できない。
        case unknown
    }

    /// - Returns: 解釈できたコマンド。できなければ空。
    static func parse(_ text: String, candidates: [Candidate]) -> [WindowCommand] {
        if case .commands(let commands) = analyze(text, candidates: candidates) { return commands }
        return []
    }

    static func analyze(_ text: String, candidates: [Candidate]) -> Analysis {
        var rest = normalize(text)
        guard !rest.isEmpty else { return .unknown }

        // ① 対象のアプリ。長い語から当て、当たった部分は消す
        //    （「google chrome」の中の「chrome」を別のアプリとして数えないため）。
        var targets: [AppTarget] = []
        let sorted = candidates
            .map { (phrase: normalize($0.phrase), target: $0.target) }
            .filter { !$0.phrase.isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
        for candidate in sorted where rest.contains(candidate.phrase) {
            rest = rest.replacingOccurrences(of: candidate.phrase, with: "")
            if !targets.contains(where: { $0.bundleID == candidate.target.bundleID }) {
                targets.append(candidate.target)
            }
        }
        // アプリが 2 つ以上 = 複数の操作。パターン照合では扱わない。
        guard targets.count <= 1 else { return .unknown }
        let target = targets.first

        // ② どのディスプレイか
        let display = extractDisplay(from: &rest)

        // ③ 知らない名前が対象になっていないか。
        //    「ズームを隠して」の「ズーム」が候補に無いとき、前面のアプリを隠してはいけない。
        //    名前だけを抜き出しておき、操作は残りから読む。
        for pronoun in pronouns { rest = rest.replacingOccurrences(of: pronoun, with: "") }
        var spokenName: String?
        if target == nil, let particle = rest.firstIndex(of: "を"), particle != rest.startIndex {
            spokenName = String(rest[..<particle])
            rest = String(rest[rest.index(after: particle)...])
        }

        // ④ 操作
        // ⚠️ キーワード側も正規化してから当てる（「センター」は本文側で長音が落ちて「センタ」になる）。
        var matches: [(action: WindowCommand.Action, word: String)] = keywords.compactMap { entry in
            guard let word = entry.words.map(normalize).first(where: rest.contains) else { return nil }
            return (entry.action, word)
        }
        // 「右半分に出して」「右のモニターに出して」の「出して」は添え物。
        // ほかの操作やディスプレイの指定があれば前面化は数えない
        // （対象を指定した操作は、どのみち前面に出してから行う）。
        if matches.count > 1 || display != nil { matches.removeAll { $0.action == .activate } }

        let command: WindowCommand
        switch matches.count {
        case 1:
            let action = matches[0].action
            // 何を前に出すのか分からない「前に出して」は実行しない。
            if action == .activate, target == nil, spokenName == nil { return .unknown }
            // 「隣の画面で最小化」のような組み合わせは意味が決まらない。
            if display != nil, !action.acceptsDisplay { return .unknown }
            guard target != nil || rest.count - matches[0].word.count <= maxExtraLength else { return .unknown }
            command = WindowCommand(action: action, target: target, display: display)
        case 0:
            if let display {
                command = WindowCommand(action: .moveToDisplay, target: target, display: display)
            } else {
                // アプリ名だけを言った（「Slack」）→ 前面に出す。
                // ⚠️ 名前のほかに長い文が付いているものは、ただの文章の可能性が高いので見送る。
                guard let target, rest.count <= 4 else { return .unknown }
                command = WindowCommand(action: .activate, target: target)
            }
        default:
            return .unknown
        }

        if let spokenName { return .needsTarget(command, spokenName: spokenName) }
        return .commands([command])
    }

    /// ディスプレイの指定を抜き出し、その部分を本文から消す。
    private static func extractDisplay(from rest: inout String) -> DisplaySelector? {
        let range = NSRange(rest.startIndex..., in: rest)
        guard let match = displayPattern?.firstMatch(in: rest, range: range),
              let whole = Range(match.range, in: rest),
              let which = Range(match.range(at: 1), in: rest)
        else { return nil }

        let selector: DisplaySelector
        switch String(rest[which]) {
        case "右": selector = .right
        case "左": selector = .left
        case "真ん中", "まんなか", "中央", "メイン": selector = .center
        default: selector = .next
        }
        rest.removeSubrange(whole)
        return selector
    }

    /// 空白・句読点を落とし、全角英数を半角に、英字を小文字にそろえる。
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "、。,.!?！？「」『』・…ー-"))
        // ⚠️ 長音「ー」を落とすのは、「ブラウザー」と「ブラウザ」を同じ扱いにするため。
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !dropped.contains($0) }))
    }
}
