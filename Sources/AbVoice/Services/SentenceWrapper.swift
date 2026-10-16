import Foundation

/// 文の区切りで改行を入れるかどうか。
///
/// 長い口述は 1 段落のベタ書きで出てくると読みにくい。句点で折り返すだけで見違える。
enum LineBreakMode: String, CaseIterable, Identifiable {
    /// 改行しない（whisper と LLM が返したまま）
    case none
    /// 「。」「！」「？」ごとに改行する
    case sentence
    /// 文ごとに改行し、さらに 1 行空ける
    case paragraph

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "改行しない"
        case .sentence: return "文の終わり（。！？）で改行する"
        case .paragraph: return "文の終わりで改行し、さらに 1 行空ける"
        }
    }
}

/// 整形の最後に、文の区切りで改行を入れる。
///
/// ⚠️ LLM に「改行して」と頼まない。頼むと本文まで書き換えられることがあるので、
///    ここは 0ms の機械処理でやる（辞書置換と同じ考え方）。
enum SentenceWrapper {
    /// 文末とみなす記号。閉じ括弧が続く場合はそこまでを 1 文に含める。
    private static let boundary: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "([。！？]+[」』）\\)】〕]*)[ 　]*")
    }()

    static func wrap(_ text: String, mode: LineBreakMode) -> String {
        guard mode != .none else { return text }
        guard let boundary, !text.isEmpty else { return text }

        let separator = mode == .paragraph ? "\n\n" : "\n"
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let broken = boundary.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1\(separator)"
        )

        // 元から改行があった場合に増えすぎないよう畳む。
        let collapsed = broken
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { result, line in
                if line.isEmpty, result.last?.isEmpty == true { return }
                result.append(line)
            }
            .joined(separator: "\n")

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
