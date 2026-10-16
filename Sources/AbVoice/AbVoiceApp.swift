import AppKit
import SwiftUI

@main
struct AbVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var coordinator = VoiceCoordinator.shared

    var body: some Scene {
        // Dock にもウィンドウにも出る普通のアプリ（LSUIElement = false）。
        WindowGroup("AbVoice Local", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // 録音中が分かるメニューバー常駐。
        MenuBarExtra {
            MenuBarContent()
        } label: {
            // ⚠️ ラベルは常に生きている。ウィンドウを閉じていても設定画面へ飛べるよう、
            //    ここから openWindow を AppNavigator に渡しておく
            //    （openWindow は View の Environment からしか取れない）。
            MenuBarLabel(icon: menuBarIcon)
        }
    }

    private var menuBarIcon: String {
        switch coordinator.displayState {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "ellipsis.circle"
        }
    }
}

/// メニューバーのアイコン。⚠️ 見た目のためだけでなく、`openWindow` の受け渡し口も兼ねる。
private struct MenuBarLabel: View {
    let icon: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: icon)
            .task {
                AppNavigator.shared.openMainWindow = { openWindow(id: "main") }
            }
    }
}

struct MenuBarContent: View {
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        Button(coordinator.state == .recording ? "録音を停止して挿入" : "録音を開始") {
            coordinator.toggle()
        }

        Button("録音を破棄") { coordinator.cancelRecording() }
            .disabled(coordinator.state != .recording)

        Button("最後の文字起こしを再挿入") {
            coordinator.reinsert(coordinator.lastInsertedText)
        }
        .disabled(coordinator.lastInsertedText.isEmpty)

        Divider()

        Button("ウィンドウを開く") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        // 文字起こしに失敗した録音があるときだけ出す（結果はクリップボードに入る）。
        if coordinator.hasFailedRecording {
            Button("直前の録音をやり直す") { coordinator.retryFailedRecording() }
        }

        Divider()

        Button("AbVoice Local を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch coordinator.displayState {
        case .idle:
            let key = KeyCodeNames.name(for: AppSettings.shared.hotKeyCode, modifiers: AppSettings.shared.hotKeyModifiers)
            return "待機中（\(key) で録音）"
        case .recording:
            return String(format: "録音中 %.0f 秒", coordinator.elapsed)
        case .processing:
            return "文字起こし中…"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // ⚠️ 通知の許可も、初回の設定が終わってから求める（終わったときに求める）。
            if AppSettings.shared.onboardingCompleted {
                Notifier.shared.requestNotificationAuthorization()
            }

            // アクセシビリティ権限が無いとホットキーも Cmd+V の合成も動かない。
            // ⚠️ 初回の設定が終わるまでは、ここでは求めない。ウィザードが 1 つずつ順に求める
            //    （起動直後にマイクとアクセシビリティのダイアログが同時に出ると、何を押せばいいか分からない）。
            if AppSettings.shared.onboardingCompleted, !Permissions.isAccessibilityTrusted {
                Permissions.promptForAccessibility()
            }

            VoiceCoordinator.shared.bootstrap()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // ウィンドウを閉じてもメニューバーで常駐し続ける。
        false
    }
}
