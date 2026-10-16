import Foundation

/// 操作の対象になるアプリ。
struct AppTarget: Equatable, Hashable {
    var bundleID: String
    /// 画面とログに出す名前。
    var name: String
}

/// どのディスプレイで行うか。左右は画面の並び（x 座標）で決める。
enum DisplaySelector: String, CaseIterable {
    case left
    case right
    /// 3 枚以上なら並びの真ん中、2 枚以下なら主画面。
    case center
    /// いまの画面の次。
    case next

    var label: String {
        switch self {
        case .left: return "左の画面"
        case .right: return "右の画面"
        case .center: return "中央の画面"
        case .next: return "隣の画面"
        }
    }
}

/// 音声コマンド 1 件ぶんのウィンドウ操作。
///
/// ⚠️ 「閉じる」「終了する」は入れない。聞き間違いで未保存の作業を失うため。
struct WindowCommand: Equatable {
    enum Action: String, CaseIterable {
        case activate
        case maximize
        case leftHalf
        case rightHalf
        case topHalf
        case bottomHalf
        case topLeftQuarter
        case topRightQuarter
        case bottomLeftQuarter
        case bottomRightQuarter
        case center
        case restore
        case minimize
        case hide
        /// 画面内の相対位置を保ったまま別のディスプレイへ移す（`display` が必須）。
        case moveToDisplay

        /// 結果表示用の一言（「Slack を右半分に」の後ろ半分）。
        var phrase: String {
            switch self {
            case .activate: return "前面に"
            case .maximize: return "最大化"
            case .leftHalf: return "左半分に"
            case .rightHalf: return "右半分に"
            case .topHalf: return "上半分に"
            case .bottomHalf: return "下半分に"
            case .topLeftQuarter: return "左上 1/4 に"
            case .topRightQuarter: return "右上 1/4 に"
            case .bottomLeftQuarter: return "左下 1/4 に"
            case .bottomRightQuarter: return "右下 1/4 に"
            case .center: return "中央に"
            case .restore: return "元の位置に"
            case .minimize: return "最小化"
            case .hide: return "隠す"
            case .moveToDisplay: return "移動"
            }
        }

        /// 配置先のディスプレイを指定できる操作か。
        var acceptsDisplay: Bool {
            switch self {
            case .activate, .restore, .minimize, .hide: return false
            default: return true
            }
        }
    }

    var action: Action
    /// nil = 前面のウィンドウ / アプリ。
    var target: AppTarget?
    /// nil = いまウィンドウがある画面。
    var display: DisplaySelector?

    /// 結果表示・「試す」欄用の一言（「右の画面で最大化」）。
    var phrase: String {
        guard let display else { return action.phrase }
        return action == .moveToDisplay ? "\(display.label)へ移動" : "\(display.label)で\(action.phrase)"
    }
}
