import Foundation

/// 整形の 1 段目。正規表現でフィラーを落とす。0ms・確実。
///
/// ⚠️ 「あの人」「なんか買った」のような意味のある語を壊さないこと。
/// 危険な語は **直後に読点が来るときだけ** 落とす。
enum FillerRemover {
    /// 単独で出てきたらほぼ確実にフィラー。
    private static let safeFillers = [
        "えーと", "えっと", "ええと", "あのー", "あのう", "そのー", "そのう",
        "うーん", "うんと", "えー", "えっ", "あー", "んー",
    ]

    /// 意味のある語と同形になりうる。**直後に読点があるときだけ**落とす。
    private static let riskyFillers = ["あの", "その", "まあ", "まー", "なんか", "ええ", "はい"]

    private static let boundary = "(?:^|(?<=[、。！？\\n\\r 　]))"

    private static let safePattern: NSRegularExpression? = {
        let alternatives = safeFillers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: "\(boundary)(?:\(alternatives))、?[ 　]*")
    }()

    private static let riskyPattern: NSRegularExpression? = {
        let alternatives = riskyFillers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: "\(boundary)(?:\(alternatives))、[ 　]*")
    }()

    private static let duplicateCommas: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "、[ 　]*(?=、)")
    }()

    private static let leadingComma: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "(?:^|(?<=[\\n\\r]))[ 　]*、[ 　]*")
    }()

    static func remove(from text: String) -> String {
        var result = text
        // フィラーが連続することがあるので 2 周する。
        for _ in 0..<2 {
            result = apply(safePattern, to: result)
            result = apply(riskyPattern, to: result)
        }
        result = apply(duplicateCommas, to: result)
        result = apply(leadingComma, to: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func apply(_ regex: NSRegularExpression?, to text: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
