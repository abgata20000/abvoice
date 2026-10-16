import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var model = ModelManager.shared

    @State private var capturingHotkey = false
    @State private var openAIKeyInput = ""
    @State private var openAIKeyMask = Keychain.masked(.openAIKey)
    @State private var inputDevices: [AudioInputDevice] = []
    @ObservedObject private var micTester = MicTester.shared
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var navigator = AppNavigator.shared
    /// ⚠️ ログイン項目の状態はシステム側が持っている。`AppSettings` には保存しない
    ///    （設定と実態がずれると、どちらが正か分からなくなる）。
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemMessage: String? = LoginItem.statusMessage

    var body: some View {
        // インジケータの「声が入っていません」から飛んできたとき、該当セクションまで送る。
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hotkeySection
                Divider()
                microphoneSection.id(AppDestination.microphoneSettings)
                Divider()
                recordingSection
                Divider()
                transcriptionSection.id(AppDestination.transcriptionSettings)
                Divider()
                formattingSection
                Divider()
                insertionSection
                Divider()
                openAISection
                Divider()
                historySection
                Divider()
                permissionSection
                Divider()
                logSection
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .onAppear { refreshInputDevices(); scrollToRequestedSection(proxy) }
        .onChange(of: navigator.settingsFocus) { _, _ in scrollToRequestedSection(proxy) }
        .onDisappear { micTester.stop() }
        }
    }

    /// インジケータから指定された場所まで送る。
    /// ⚠️ 送ったら要求を消す。残しておくと、次に設定を開いたときに勝手にスクロールする。
    private func scrollToRequestedSection(_ proxy: ScrollViewProxy) {
        guard let focus = navigator.settingsFocus else { return }
        withAnimation { proxy.scrollTo(focus, anchor: .top) }
        navigator.settingsFocus = nil
    }

    // MARK: マイク

    private func refreshInputDevices() {
        inputDevices = AudioDeviceManager.inputDevices()
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("マイク").font(.headline)
                Spacer()
                Button {
                    refreshInputDevices()
                } label: {
                    Label("再検出", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            Picker("入力デバイス", selection: Binding(
                get: { settings.inputDeviceUID ?? "" },
                set: { newValue in
                    micTester.stop()
                    settings.inputDeviceUID = newValue.isEmpty ? nil : newValue
                }
            )) {
                Text(systemDefaultLabel).tag("")
                ForEach(inputDevices) { device in
                    Text("\(device.name)（\(device.channels) ch）").tag(device.id)
                }
            }

            Text("⚠️ クラムシェル（蓋を閉じた状態）では内蔵マイクが使えません。外部マイクを明示的に選んでおくと、システム既定が内蔵マイクに戻っても影響を受けません。選んだデバイスは記憶され、次回起動時もそのまま使われます。")
                .font(.caption).foregroundStyle(.secondary)

            if settings.inputDeviceUID != nil, !inputDevices.contains(where: { $0.id == settings.inputDeviceUID }) {
                Label("選択中のマイクが見つかりません（外されている可能性）。録音時はシステム既定に切り替わります。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            // 喋る前に「拾えているか」を確かめられるようにする。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button(micTester.isRunning ? "テストを止める" : "マイクをテスト") {
                        micTester.toggle(inputDeviceUID: settings.inputDeviceUID)
                    }
                    .controlSize(.small)

                    LevelMeter(level: micTester.level)
                        .frame(height: 8)

                    if micTester.isRunning {
                        Text(micTester.heardSomething ? "拾えています" : "無音")
                            .font(.caption)
                            .foregroundStyle(micTester.heardSomething ? Color.green : Color.secondary)
                            .frame(width: 76, alignment: .leading)
                    }
                }
                if micTester.isRunning {
                    Text("何か喋ってバーが動けば、そのマイクで録音できます。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let message = micTester.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var systemDefaultLabel: String {
        if let device = AudioDeviceManager.defaultInputDevice() {
            return "システム既定（\(device.name)）"
        }
        return "システム既定"
    }

    // MARK: ログ

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近の動作ログ").font(.headline)
            if notifier.entries.isEmpty {
                Text("まだ何も記録されていません。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(notifier.entries.prefix(15)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Formatters.time.string(from: entry.at))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(color(for: entry.level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("ホットキーを押しても何も起きないときは、ここに理由が出ていないか見てください。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    // MARK: ホットキー

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ホットキー").font(.headline)
            HStack(spacing: 12) {
                Text(KeyCodeNames.name(for: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
                    .font(.title3.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                // ⚠️ キーの名前を人間が判断しなくて済むよう、実際に押されたキーを拾って登録する。
                Button(capturingHotkey ? "キーを押してください…" : "キーを記録") {
                    if capturingHotkey {
                        coordinator.cancelHotkeyCapture()
                        capturingHotkey = false
                    } else {
                        capturingHotkey = true
                        coordinator.beginHotkeyCapture { code, modifiers in
                            settings.hotKeyCode = code
                            settings.hotKeyModifiers = modifiers
                            coordinator.applyHotkeySettings()
                            capturingHotkey = false
                        }
                    }
                }
                .disabled(!coordinator.hotkeyActive)

                Button("⌃⌥Space に戻す") {
                    settings.hotKeyCode = 49
                    settings.hotKeyModifiers = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
                    coordinator.applyHotkeySettings()
                }
                .controlSize(.small)
            }
            Text("ほかのアプリと重ならないキーを「キーを記録」で決めてください。Escape はいつでも「録音を破棄」に固定。")
                .font(.caption).foregroundStyle(.secondary)

            Picker("録音モード", selection: Binding(
                get: { settings.recordingMode },
                set: { settings.recordingMode = $0; coordinator.applyHotkeySettings() }
            )) {
                ForEach(RecordingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: 録音

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("録音").font(.headline)

            Toggle("無音が続いたら止める（止め忘れ防止）", isOn: $settings.silenceStopEnabled)
            HStack {
                Slider(value: $settings.silenceStopSeconds, in: 5...120, step: 5)
                    .disabled(!settings.silenceStopEnabled)
                Text("\(Int(settings.silenceStopSeconds)) 秒")
                    .monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            Text("""
            ⚠️ 喋り終わりを検出して自動で止める機能ではありません。考えながら黙っても止まりません。\
            喋り出しを検出した後、この秒数だけ無音が続いたときにだけ「止め忘れ」として停止します。
            """)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("最長録音時間（安全弁）")
                Spacer()
                Stepper("\(Int(settings.maxRecordingSeconds / 60)) 分",
                        value: $settings.maxRecordingSeconds, in: 60...3600, step: 60)
            }

            Toggle("開始・停止を音で知らせる", isOn: $settings.soundFeedbackEnabled)
            Text("停止に気づかず喋り続ける事故を防ぐため、既定で ON にしています。")
                .font(.caption).foregroundStyle(.secondary)

            Picker("インジケータの位置", selection: $settings.indicatorPosition) {
                ForEach(IndicatorPosition.allCases) { position in
                    Text(position.label).tag(position)
                }
            }
            Text("録音中の表示を出す場所。録音中は小さく、挿入結果を出すときだけ広がります。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("喋りながら速報を表示する（オンデバイス・課金なし）", isOn: $settings.realtimePreviewEnabled)
                .disabled(!RealtimeTranscriber.isSupported)
            Text(RealtimeTranscriber.isSupported ? """
            喋っている間、認識した内容をインジケータに出します。⚠️ 速報は表示だけで、\
            挿入されるのは停止後の確定テキスト（文字起こし + 整形 + 辞書）です。\
            速報で固有名詞を取りこぼしても、挿入されるテキストは直っています。
            """ : "この Mac では速報を使えません（macOS 26 以降のオンデバイス認識が必要）。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("ログイン時に自動で起動する", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginItemMessage {
                HStack(spacing: 8) {
                    Text(loginItemMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("システム設定を開く") { LoginItem.openSystemSettings() }
                        .controlSize(.small)
                }
            } else {
                Text("再起動のたびに手で起動しなくて済みます。システム設定の「ログイン項目」にも並びます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // 設定画面を開き直したときにシステム側の実態と合わせる。
        .onAppear { syncLoginItemState() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            Notifier.shared.error("ログイン項目を変更できませんでした: \(error.localizedDescription)")
        }
        syncLoginItemState()
    }

    private func syncLoginItemState() {
        launchAtLogin = LoginItem.isEnabled
        loginItemMessage = LoginItem.statusMessage
    }

    // MARK: 整形

    private var formattingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整形").font(.headline)

            Picker("改行", selection: $settings.lineBreakMode) {
                ForEach(LineBreakMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("長い口述を 1 段落のまま貼ると読みにくいので、文の区切りで折り返せます。ペーストで挿入するため、改行が入っても Slack などで勝手に送信されることはありません。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("正規表現でフィラーを除去する", isOn: $settings.fillerRemovalEnabled)
            Toggle("LLM で整形する（言い淀みの除去・句読点の補完）", isOn: $settings.formattingEnabled)

            Picker("整形に使う LLM", selection: Binding(
                get: { settings.formatProvider },
                set: { settings.formatProvider = $0; Task { await coordinator.refreshFormatStatus() } }
            )) {
                ForEach(FormatProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!settings.formattingEnabled)
            Text("⚠️ 選んだもの以外には切り替わりません。Ollama が動いていないときは、整形なしで挿入します。")
                .font(.caption).foregroundStyle(.secondary)

            ollamaStatusRow

            HStack {
                Text("Ollama のモデル")
                TextField("gemma3:4b", text: $settings.formatModel).frame(width: 180)
            }
            LabeledContent("Ollama のアドレス") { TextField("http://localhost:11434", text: $settings.ollamaBaseURL) }
            Text("""
            ⚠️ 大きいモデル（27B 級以上）は使わないこと。遅いうえに固有名詞を別の語に書き換える実測があります。
            辞書の置き換え（誤変換 → 正しい表記）は LLM 整形の後に必ず適用されます。
            """)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("OpenAI のモデル")
                TextField("gpt-4o-mini", text: $settings.openAIFormatModel).frame(width: 180)
            }
        }
    }

    /// この Mac の Ollama が使えるか。⚠️ 定期的には調べない。「調べ直す」を押したときだけ。
    private var ollamaStatusRow: some View {
        HStack(spacing: 8) {
            switch coordinator.ollamaStatus {
            case .ready:
                Label("Ollama: 使えます", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .modelMissing:
                if let progress = coordinator.ollamaPullProgress {
                    ProgressView(value: progress).frame(width: 160)
                    Text("モデルを取得中 \(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Label("Ollama: 動いていますが、モデル「\(settings.formatModel)」がありません",
                          systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Button("モデルを取得") { Task { await coordinator.pullOllamaModel() } }
                }
            case .notRunning:
                Label("Ollama を入れると、言い淀みの除去や句読点の補完が効きます",
                      systemImage: "info.circle").foregroundStyle(.secondary)
                Button("公式サイトを開く") {
                    if let url = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(url) }
                }
            case .unknown:
                Label("Ollama: 未確認", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            Spacer()
            Button("調べ直す") { Task { await coordinator.refreshFormatStatus() } }
        }
        .font(.caption)
        .controlSize(.small)
    }

    // MARK: 文字起こし

    /// 選んでいるモデルの状態と、取得・削除のボタン。
    private var modelStatusRow: some View {
        HStack(spacing: 8) {
            switch model.status {
            case .ready:
                Label("モデル: 使えます", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("削除") { Task { await model.delete(variant: settings.whisperModel) } }
            case .notDownloaded:
                Label("モデル: まだありません", systemImage: "arrow.down.circle").foregroundStyle(.orange)
                Spacer()
                Button("取得する") { Task { await model.downloadAndPrepare(variant: settings.whisperModel) } }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 160)
                Text("取得中 \(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            case .preparing:
                ProgressView().controlSize(.small)
                Text("準備中（取得した直後は数分かかります）").foregroundStyle(.secondary)
                Spacer()
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("もう一度") { Task { await model.downloadAndPrepare(variant: settings.whisperModel) } }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文字起こし").font(.headline)

            Picker("どこで文字起こしするか", selection: $settings.transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("""
            ⚠️「この Mac の中」を選んでいる間は、失敗しても OpenAI には送りません。\
            「OpenAI」を選んだときだけ音声が送られ、届かなかったときはこの Mac の中で文字起こしします。
            """)
                .font(.caption).foregroundStyle(.secondary)

            Picker("この Mac で使うモデル", selection: Binding(
                get: { settings.whisperModel },
                set: { newValue in
                    settings.whisperModel = newValue
                    Task { await model.prepare(variant: newValue) }
                }
            )) {
                ForEach(WhisperModelChoice.allCases) { Text($0.label).tag($0.rawValue) }
            }
            modelStatusRow
            Text("""
            モデルは初回に 1 度だけインターネットから取得し、この Mac に保存します（アプリには入っていません）。\
            取得した直後の 1 回目だけ、この Mac 向けの準備に数分かかります。
            """)
                .font(.caption).foregroundStyle(.secondary)

            Picker("辞書の語をヒントに渡す", selection: $settings.dictionaryPromptTerms) {
                Text("渡さない（既定・いちばん速い）").tag(0)
                Text("10 語まで（約 0.5 秒遅くなる）").tag(10)
                Text("20 語まで（約 1 秒遅くなる）").tag(20)
            }
            Text("""
            渡すと固有名詞を聞き取りやすくなりますが、語数に比例して遅くなります。\
            渡さなくても、辞書の置き換え（誤変換 → 正しい表記）は必ず効きます。
            """)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("OpenAI のモデル")
                TextField("gpt-4o-transcribe", text: $settings.openAITranscribeModel).frame(width: 180)
            }
        }
    }

    // MARK: 挿入

    private var insertionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("挿入").font(.headline)
            Picker("挿入方法", selection: $settings.insertionMethod) {
                ForEach(InsertionMethod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("⚠️ パスワードフィールドにフォーカスがあるときは、設定にかかわらず録音も挿入も行いません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: OpenAI

    private var openAISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI（任意）").font(.headline)
            Text("""
            文字起こし・整形で「OpenAI」を選んだときにだけ使います。\
            登録しただけでは何も送られません。
            """)
                .font(.caption).foregroundStyle(.secondary)

            secretField(
                title: "OpenAI API キー",
                mask: openAIKeyMask,
                input: $openAIKeyInput,
                onSave: {
                    Keychain.write(.openAIKey, openAIKeyInput)
                    openAIKeyInput = ""
                    openAIKeyMask = Keychain.masked(.openAIKey)
                },
                onClear: {
                    Keychain.delete(.openAIKey)
                    openAIKeyMask = Keychain.masked(.openAIKey)
                }
            )

            Text("API キーは Keychain に保存されます（UserDefaults には置きません）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func secretField(
        title: String,
        mask: String,
        input: Binding<String>,
        onSave: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(mask).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("新しい値を貼り付け", text: input)
                Button("保存", action: onSave).disabled(input.wrappedValue.isEmpty)
                Button("削除", action: onClear)
            }
            .controlSize(.small)
        }
    }

    // MARK: 履歴

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("履歴").font(.headline)
            Toggle("履歴を残す", isOn: $settings.historyEnabled)
            Picker("残す期間", selection: $settings.historyRetentionDays) {
                Text("30 日").tag(30)
                Text("90 日（既定）").tag(90)
                Text("無期限").tag(0)
            }
            .disabled(!settings.historyEnabled)
            Text("""
            履歴はこの Mac のファイルにだけ保存されます（音声は保存しません）。\
            期間を過ぎた分は、次にアプリを起動したときに消えます。
            """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 権限

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("権限").font(.headline)
            HStack {
                Label(
                    coordinator.hotkeyActive ? "アクセシビリティ: 許可済み" : "アクセシビリティ: 未許可",
                    systemImage: coordinator.hotkeyActive ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(coordinator.hotkeyActive ? .green : .orange)
                Spacer()
                Button("許可を求める") { Permissions.promptForAccessibility() }
                Button("システム設定を開く") { Permissions.openAccessibilitySettings() }
                Button("再接続") { coordinator.startHotkey() }
            }
            .controlSize(.small)
            HStack {
                Text("マイク")
                Spacer()
                Button("システム設定を開く") { Permissions.openMicrophoneSettings() }.controlSize(.small)
            }
            Text("ホットキーの監視と Cmd+V の合成には、アクセシビリティ権限が必要です。")
                .font(.caption).foregroundStyle(.secondary)
            Button("初回の設定をやり直す") { settings.onboardingCompleted = false }
                .controlSize(.small)
        }
    }
}
