import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case history, dictionary, commands, stats, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "履歴"
        case .dictionary: return "辞書"
        case .commands: return "コマンド"
        case .stats: return "統計"
        case .settings: return "設定"
        }
    }

    var icon: String {
        switch self {
        case .history: return "waveform"
        case .dictionary: return "character.book.closed"
        case .commands: return "macwindow.on.rectangle"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

/// メニューバーだけのアプリにしない。履歴を主役にした普通の Mac アプリの形にする。
struct MainWindow: View {
    @State private var selection: SidebarSection = .history
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var navigator = AppNavigator.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // 初めて起動したときだけ、初回の設定を先に出す。
        if settings.onboardingCompleted {
            mainContent
        } else {
            OnboardingView()
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SidebarSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
                Divider()
                ConnectionStatusView()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = notifier.lastError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button("閉じる") { notifier.lastError = nil }.controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.12))
                }

                switch selection {
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .commands: CommandsView()
                case .stats: StatsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 820, minHeight: 560)
        // インジケータから「設定を開いて」と言われたら従う。
        .onChange(of: navigator.section) { _, section in selection = section }
        .onAppear { if navigator.settingsFocus != nil { selection = navigator.section } }
    }
}

/// サイドバー下部に常時出す状態。
/// ⚠️ 定期ポーリングはしない。最後の結果を色で出すだけ。
struct ConnectionStatusView: View {
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var dictionary = LocalDictionaryStore.shared
    @ObservedObject private var model = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状態").font(.caption.bold()).foregroundStyle(.secondary)
            row(transcriptionTitle, transcriptionState)
            // 取得中・準備中は、あとどのくらいかが分かるように文で出す。
            if settings.transcriptionEngine == .local, model.status != .ready {
                Text(model.statusText).font(.caption2).foregroundStyle(.secondary)
            }
            row(formatTitle, formatState)

            if coordinator.hasFailedRecording {
                HStack {
                    Image(systemName: "arrow.counterclockwise").font(.caption2).foregroundStyle(.secondary)
                    Text("失敗した録音 1 件").font(.caption)
                    Spacer()
                    Button("やり直す") { coordinator.retryFailedRecording() }
                        .controlSize(.mini)
                }
            }

            Text("辞書 \(dictionary.entries.count) 語")
                .font(.caption2).foregroundStyle(.secondary)

            if !coordinator.hotkeyActive {
                Label("アクセシビリティ未許可", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
    }

    private var transcriptionTitle: String {
        settings.transcriptionEngine == .local ? "文字起こし（この Mac）" : "文字起こし（OpenAI）"
    }

    /// この Mac の中のときはモデルの状態、OpenAI のときは直近の結果。
    private var transcriptionState: Bool? {
        guard settings.transcriptionEngine == .local else { return coordinator.transcriptionOK }
        switch model.status {
        case .ready: return true
        case .failed: return false
        case .notDownloaded, .downloading, .preparing: return nil
        }
    }

    /// 整形の行。いま実際に使われるものを名前で出す。
    private var formatTitle: String {
        switch coordinator.activeFormatProvider {
        case .ollama: return "整形（Ollama）"
        case .openai: return "整形（OpenAI）"
        case .none, .auto: return "整形（なし）"
        }
    }

    /// 整形しない設定は故障ではないので、赤ではなく「未確認」と同じグレーで出す。
    private var formatState: Bool? {
        switch coordinator.activeFormatProvider {
        case .ollama: return coordinator.ollamaStatus == .ready
        case .openai: return true
        case .none, .auto: return nil
        }
    }

    private func row(_ title: String, _ state: Bool?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: state))
                .frame(width: 8, height: 8)
            Text(title).font(.caption)
            Spacer()
        }
        .help(state == nil
              ? "まだ使っていません（定期的な確認はしていません）"
              : (state! ? "最後の結果は成功" : "最後の結果は失敗"))
    }

    private func color(for state: Bool?) -> Color {
        switch state {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary.opacity(0.4)
        }
    }
}
