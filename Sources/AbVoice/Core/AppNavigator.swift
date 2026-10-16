import AppKit
import Foundation

/// 画面のどこへ飛ばすか。
///
/// ⚠️ 「設定を直せば解決するもの」だけを用意する。ハルシネーション破棄やパスワード
///    フィールドでの破棄は、設定画面を開いても何もできないので飛び先を持たせない。
enum AppDestination: Equatable {
    case microphoneSettings
    case transcriptionSettings

    /// インジケータに出す一言。⚠️ 出さないと押せることに気づけない。
    var hint: String {
        switch self {
        case .microphoneSettings: return "クリックしてマイクの設定を開く"
        case .transcriptionSettings: return "クリックして文字起こしの設定を開く"
        }
    }
}

/// メインウィンドウを開いて目的の場所まで連れて行く係。
///
/// ⚠️ `openWindow` は SwiftUI の `View` の Environment からしか取れない。
///    ウィンドウを閉じている状態でも開けるよう、常駐している `MenuBarExtra` から
///    `openMainWindow` を注入してもらう（`AbVoiceApp.swift`）。
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    /// メインウィンドウを開く手段。起動時に注入される。
    var openMainWindow: (() -> Void)?

    /// サイドバーで選んでほしいセクション。
    @Published var section: SidebarSection = .history
    /// 設定画面のどこまでスクロールしてほしいか。読み終わったら nil に戻す。
    @Published var settingsFocus: AppDestination?

    private init() {}

    /// ⚠️ 挿入先を奪う心配はない。ここへ来るのは挿入が終わった（あるいは行われなかった）後だけ。
    func go(to destination: AppDestination) {
        section = .settings
        settingsFocus = destination
        NSApp.activate(ignoringOtherApps: true)
        // ⚠️ 注入が効いていないと、押しても何も起きない「無反応」になる。
        //    黙って諦めず、メニューバーから開ける旨を伝える。
        guard let openMainWindow else {
            Notifier.shared.warn("ウィンドウを開けませんでした。メニューバーの AbVoice Local から開いてください。", notify: true)
            return
        }
        openMainWindow()
    }
}
