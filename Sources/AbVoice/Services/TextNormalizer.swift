import Foundation

/// whisper の出力そのままだと使えない形を直す。
///
/// ⚠️ 文字起こしエンジンはセグメント境界で改行を入れることがある。それが **単語の途中に来る**ことがある。
///    2026-08-19 の実測: `リポジトリのバックエ\nンドに実装したい`
///    整形 OFF のときはこの改行がそのまま貼られてしまうので、ここで畳む。
enum TextNormalizer {
    static func joinSegments(_ text: String) -> String {
        var result = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = line.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if result.isEmpty {
                result = piece
                continue
            }
            // 英数字どうしが隣り合うときだけ空白を入れる。日本語はそのまま繋ぐ。
            if let last = result.last, let first = piece.first, isASCIIWord(last), isASCIIWord(first) {
                result += " " + piece
            } else {
                result += piece
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isASCIIWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
