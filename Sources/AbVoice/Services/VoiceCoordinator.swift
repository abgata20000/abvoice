import AppKit
import AVFoundation
import Foundation

enum VoiceState: Equatable {
    case idle
    case recording
    case processing
}

/// 録音の用途。⚠️ 開始時に決まり、途中で変わらない（どちらのキーで始めたか）。
enum RecordingPurpose {
    /// 口述。文字起こし → 整形 → カーソル位置に挿入。
    case dictation
    /// 音声コマンド。文字起こし → 解釈 → ウィンドウ操作。何も挿入しない。
    case command
}

/// ホットキー → 録音 → 文字起こし → 整形 → 挿入 → 履歴に追記、の一連を束ねる。
///
/// ⚠️ 録音は保存しない。文字起こしが済んだら捨てる。
///    失敗したときだけ、直近の 1 件をメモリに持って再試行できるようにする（ディスクには書かない）。
/// ⚠️ 履歴への追記が失敗しても挿入は成功させる。
@MainActor
final class VoiceCoordinator: ObservableObject {
    static let shared = VoiceCoordinator()

    /// ⚠️ 録音しているかどうかだけを持つ。文字起こし中かどうかは processingCount で別に数える。
    ///    処理中に次の発話を始められないと、押下が丸ごと無視されて「反応しない」ように見える。
    @Published private(set) var state: VoiceState = .idle
    /// 走っている文字起こしパイプラインの本数。
    @Published private(set) var processingCount = 0

    /// 画面表示用。録音が最優先、次に処理中。
    var displayState: VoiceState {
        if state == .recording { return .recording }
        return processingCount > 0 ? .processing : .idle
    }
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastInsertedText: String = ""
    @Published private(set) var lastLatencyMs: Int?
    @Published private(set) var lastEngine: String?

    /// 整形の状態。⚠️ ポーリングはしない。起動時と、設定画面のボタンを押したときに調べた結果を持つだけ。
    @Published private(set) var ollamaStatus: OllamaStatus = .unknown
    /// いま実際に整形に使われるプロバイダ（`auto` を解決したあとの値）。
    @Published private(set) var activeFormatProvider: FormatProvider = .none
    /// 直近の文字起こしの成否。まだ 1 回もしていなければ nil。
    @Published private(set) var transcriptionOK: Bool?

    /// 文字起こしに失敗した直近の 1 件。再試行のためにメモリにだけ持つ。
    /// ⚠️ ディスクには書かない。アプリを終了すれば消える。
    private var failedRecording: FailedRecording?
    @Published private(set) var hasFailedRecording = false

    private struct FailedRecording {
        var wav: Data
        var duration: TimeInterval
        var appName: String?
        var appBundleID: String?
    }

    @Published private(set) var hotkeyActive = false

    /// いまどの段階にいるか。⚠️ 停止から挿入までが無表示だと「無反応」に見えるので必ず出す。
    @Published private(set) var stage: PipelineStage = .idle
    /// 処理を始めてからの経過秒。インジケータに出す。
    @Published private(set) var processingElapsed: TimeInterval = 0
    /// いまの表示をクリックしたときの飛び先。nil ならクリックできない。
    /// ⚠️ `PipelineStage` に case を足さず別に持つ。enum を触ると分岐が全箇所に散っているため。
    /// ⚠️ 「設定を直せば解決するもの」だけに付ける。ハルシネーション破棄やパスワード
    ///    フィールドでの破棄は、設定画面を開いても何もできない。
    @Published private(set) var stageDestination: AppDestination?

    private var stageHideWorkItem: DispatchWorkItem?
    private var processingStartedAt: Date?
    private var processingTimer: Timer?

    private let recorder = AudioRecorder()
    private let watchdog = SilenceWatchdog(threshold: 30)
    private let hotkey = HotkeyMonitor()
    /// 喋っている間の速報。⚠️ 表示専用。挿入には使わない。
    let realtime = RealtimeTranscriber()

    private var tickTimer: Timer?
    private var recordingStartedAt: Date?
    private var maxLevelDuringRecording: Float = 0
    /// いまの（直近の）録音の用途。インジケータが口述とコマンドを見分けるのに使う。
    @Published private(set) var recordingPurpose: RecordingPurpose = .dictation

    private init() {}

    // MARK: 起動

    func bootstrap() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.consume(level: value) }
        }
        // ⚠️ onLevel と同じく、ここで 1 回だけ張って以後は差し替えない。
        //    録音ごとに付け替えると、tap スレッドが読んでいる最中の代入と競合する。
        //    速報を使っていないときは feed 側が即座に捨てる。
        recorder.onBuffer = { [realtime] buffer in realtime.feed(buffer) }
        // 速報が出た / 消えたときだけインジケータの幅を変える。
        realtime.onPreviewVisibilityChanged = { hasPreview in
            RecordingIndicator.shared.updatePreview(hasPreview: hasPreview)
        }
        watchdog.onTimeout = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                // 声の検出のために監視は常に回している。停止させるのは ON のときだけ。
                guard AppSettings.shared.silenceStopEnabled else { return }
                Notifier.shared.warn("無音が \(Int(AppSettings.shared.silenceStopSeconds)) 秒続いたため録音を止めました。", notify: true)
                self.stopAndProcess()
            }
        }

        hotkey.isRecording = { [weak self] in
            MainActor.assumeIsolated { self?.state == .recording }
        }
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onStartCommand = { [weak self] in self?.startRecording(purpose: .command) }
        hotkey.onStop = { [weak self] in self?.stopAndProcess() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }

        applyHotkeySettings()
        _ = startHotkey()

        let settings = AppSettings.shared
        LocalHistoryStore.shared.prune(retentionDays: settings.historyRetentionDays)

        // 起動時にモデルをメモリへ載せておく（最初の 1 回だけ遅い、を避ける）。
        // ⚠️ 初回の設定の前は取りに行かない（どのモデルにするかをウィザードで選んでもらうため）。
        //    初回の設定を終えているのにモデルが無いときだけ、ここで取得を始める。
        //    取得しないまま設定を終えた人・取得に失敗したままの人が、何も文字にできない状態で止まらないように
        //    （v0.1.0 で実際に起きた）。
        Task {
            let manager = ModelManager.shared
            await manager.prepare(variant: settings.whisperModel)
            if settings.onboardingCompleted, settings.transcriptionEngine == .local, manager.status == .notDownloaded {
                Notifier.shared.info("文字起こしモデルが無いので取得を始めます")
                await manager.downloadAndPrepare(variant: settings.whisperModel)
            }
        }

        Task {
            // ⚠️ 初回の設定が終わるまでは、マイクの許可も求めない（ウィザードが順に求める）。
            if settings.onboardingCompleted {
                _ = await AudioRecorder.ensureMicrophoneAccess()
            }
            await refreshFormatStatus()
            // 起動時にモデルを載せておく（冷えた初回の 13 秒を避ける）。Ollama を使うときだけ働く。
            await FormatService.shared.warmUp(config: snapshotConfig().format)
        }
    }

    /// Ollama に整形用のモデルを取得させている最中の進み具合（0〜1）。取得していなければ nil。
    @Published private(set) var ollamaPullProgress: Double?

    /// Ollama に整形用のモデルを取得させ、終わったら状態を調べ直す。
    func pullOllamaModel() async {
        guard ollamaPullProgress == nil else { return }
        ollamaPullProgress = 0
        defer { ollamaPullProgress = nil }
        let config = snapshotConfig().format
        Notifier.shared.info("Ollama にモデルの取得を頼みました（\(config.model)）")
        do {
            try await FormatService.shared.pullOllamaModel(config: config) { fraction in
                Task { @MainActor in
                    guard VoiceCoordinator.shared.ollamaPullProgress != nil else { return }
                    VoiceCoordinator.shared.ollamaPullProgress = fraction
                }
            }
        } catch {
            Notifier.shared.error("Ollama のモデルを取得できませんでした: \(error.localizedDescription)", notify: false)
        }
        await refreshFormatStatus()
    }

    /// Ollama があるかを調べ直し、いま整形に使われるプロバイダを更新する。
    /// ⚠️ 定期的には呼ばない。起動時と、設定を変えたとき・ボタンを押したときだけ。
    func refreshFormatStatus() async {
        let config = snapshotConfig().format
        ollamaStatus = await FormatService.shared.detectOllama(config: config)
        activeFormatProvider = await FormatService.shared.resolvedProvider(config)
        Notifier.shared.info("整形: \(activeFormatProvider.rawValue)（Ollama の状態: \(ollamaStatus)）")
    }

    func applyHotkeySettings() {
        let settings = AppSettings.shared
        hotkey.configure(
            keyCode: settings.hotKeyCode,
            modifiers: settings.hotKeyModifiers,
            mode: settings.recordingMode
        )
        hotkey.configureCommand(
            keyCode: settings.commandHotKeyCode,
            modifiers: settings.commandHotKeyModifiers,
            enabled: settings.commandsEnabled
        )
    }

    @discardableResult
    func startHotkey() -> Bool {
        let ok = hotkey.start()
        hotkeyActive = ok
        if !ok {
            Notifier.shared.warn("アクセシビリティ権限が無いためホットキーを監視できません。設定画面から許可してください。")
        }
        return ok
    }

    func beginHotkeyCapture(_ handler: @escaping (Int, UInt64) -> Void) {
        hotkey.onCapture = { code, modifiers in
            Task { @MainActor in handler(Int(code), modifiers) }
        }
        hotkey.beginCapture()
    }

    func cancelHotkeyCapture() {
        hotkey.cancelCapture()
    }

    // MARK: 録音

    func toggle() {
        if state == .recording {
            stopAndProcess()
        } else {
            startRecording()
        }
    }

    func startRecording(purpose: RecordingPurpose = .dictation) {
        guard state == .idle else {
            Notifier.shared.warn("録音開始を無視しました（すでに録音中）")
            return
        }

        // ⚠️⚠️ パスワードフィールドにフォーカスがあるときは録音も挿入も行わない。
        //    コマンドは何も挿入せず画面の文字も読まないので、この判定は口述のときだけ。
        if purpose == .dictation, ContextReader.read(includeSnippet: false).isSecureField {
            Notifier.shared.warn("パスワードフィールドのため録音しませんでした。", notify: true)
            Notifier.shared.playErrorSound()
            return
        }

        // ⚠️ この Mac の中で文字起こしする設定なのにモデルが使えないときは、録音を始めない。
        //    喋らせてから「文字起こしできません」と言うより、押した時点で理由を出す。
        if AppSettings.shared.transcriptionEngine == .local, ModelManager.shared.status != .ready {
            let message = ModelManager.shared.statusText
            setStage(.failed(message), destination: .transcriptionSettings)
            Notifier.shared.warn("録音しませんでした: \(message)")
            Notifier.shared.playErrorSound()
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Notifier.shared.error("マイクが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で許可してください。")
            Task { _ = await AudioRecorder.ensureMicrophoneAccess() }
            return
        }

        do {
            try recorder.start(inputDeviceUID: AppSettings.shared.inputDeviceUID)
        } catch {
            Notifier.shared.error(error.localizedDescription)
            Notifier.shared.playErrorSound()
            return
        }

        let settings = AppSettings.shared
        watchdog.threshold = settings.silenceStopSeconds
        watchdog.start()

        state = .recording
        recordingPurpose = purpose
        level = 0
        maxLevelDuringRecording = 0
        elapsed = 0
        recordingStartedAt = Date()

        // 速報（オンデバイス・課金ゼロ）。⚠️ 失敗しても録音と挿入は今までどおり動かす。
        if settings.realtimePreviewEnabled, RealtimeTranscriber.isSupported,
           let inputFormat = recorder.inputFormat {
            let realtime = self.realtime
            let terms = LocalDictionaryStore.shared.contextualStrings
            Task { await realtime.start(inputFormat: inputFormat, contextualStrings: terms) }
        }

        if purpose == .command {
            Notifier.shared.playCommandStartSound()
            Notifier.shared.info("録音開始（コマンド）")
        } else {
            Notifier.shared.playStartSound()
            Notifier.shared.info("録音開始")
        }
        setStage(.recording)

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in VoiceCoordinator.shared.tick() }
        }
    }

    func stopAndProcess() {
        guard state == .recording else { return }
        let stoppedAt = Date()
        // ⚠️ しきい値は思い切り下げる。落とすべきは「マイクが死んでいる」ときだけで、
        //    小さい声を取りこぼす方がずっと害が大きい（実測 0.02 は高すぎて短い発話が全滅した）。
        //    喋り出しが計測窓に入るとノイズフロアも上振れするので、相対値は判定に使わない。
        let heardVoice = watchdog.didHearVoice || maxLevelDuringRecording >= 0.004

        teardownRecording()
        let captured = recorder.stop()
        Notifier.shared.playStopSound()

        let purpose = recordingPurpose

        // ⚠️ 挿入先は「停止時点でフォーカスされているアプリ」。
        // 画面の文字は読まない（どこにも送らないので要らない）。
        let focus = ContextReader.read(includeSnippet: false)
        if purpose == .dictation, focus.isSecureField {
            state = .idle
            setStage(.failed("パスワードフィールドのため録音を破棄しました"))
            Notifier.shared.warn("パスワードフィールドのため録音を破棄しました。", notify: true)
            return
        }

        guard let captured, captured.duration >= 0.4, heardVoice else {
            state = .idle
            Notifier.shared.info(String(
                format: "録音停止（挿入なし）: 長さ %.1f 秒 / peak %.4f / ノイズフロア %.4f / 録音データ %@",
                captured?.duration ?? 0, maxLevelDuringRecording, watchdog.noiseFloor,
                captured == nil ? "なし" : "あり"
            ))
            if let detail = recorder.lastConversionError {
                // ⚠️ マイクは拾えているのに変換で落ちている場合。無音と区別して出す。
                let message = AudioRecorderError.conversionFailed(detail).localizedDescription
                setStage(.failed(message), destination: .microphoneSettings)
                Notifier.shared.error(message)
                Notifier.shared.playErrorSound()
            } else {
                // 喋っていないだけなので失敗扱いにはしない。
                // ⚠️ マイクの選択が外れているのが典型なので、設定へ飛べるようにする。
                setStage(.skipped("何も挿入していません"), destination: .microphoneSettings)
                Notifier.shared.info("声が入っていなかったため何も挿入しませんでした。")
            }
            return
        }

        state = .idle
        processingCount += 1
        Notifier.shared.info(String(
            format: "録音停止 %.1f 秒 / peak %.4f / ノイズフロア %.4f / 挿入先 %@ / 文字起こしへ",
            captured.duration, maxLevelDuringRecording, watchdog.noiseFloor, focus.appName ?? "不明"
        ))
        setStage(.transcribing)
        let config = snapshotConfig()
        if purpose == .command {
            // ⚠️ 対象を言わなかったときの「前面のウィンドウ」も停止時点で決める。
            let frontmost = NSWorkspace.shared.frontmostApplication
            Task {
                await runCommandPipeline(
                    wav: captured.wav,
                    duration: captured.duration,
                    frontmost: frontmost,
                    stoppedAt: stoppedAt,
                    config: config
                )
            }
            return
        }
        Task {
            await runPipeline(
                wav: captured.wav,
                duration: captured.duration,
                focus: focus,
                stoppedAt: stoppedAt,
                config: config
            )
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        teardownRecording()
        recorder.discard()
        state = .idle
        setStage(.idle)
        Notifier.shared.playCancelSound()
        Notifier.shared.info("録音を破棄しました。")
    }

    /// 段階を切り替え、インジケータの表示・非表示を面倒みる。
    private func setStage(_ next: PipelineStage, destination: AppDestination? = nil) {
        stageHideWorkItem?.cancel()
        stageHideWorkItem = nil
        stage = next
        stageDestination = destination

        guard next.isVisible else {
            RecordingIndicator.shared.hide()
            stopProcessingTimer()
            return
        }
        RecordingIndicator.shared.show(for: next, destination: destination)

        switch next {
        case .transcribing, .formatting, .inserting:
            startProcessingTimer()
        case .done, .failed, .skipped:
            stopProcessingTimer()
            // 成功は短く消す（挿入されたテキスト自体が見えているので確認は一瞬でよい）。
            // 失敗は読む時間が要るので長く残す。
            // 何も挿入しなかっただけの skipped は失敗ではないので、その中間。
            let delay: TimeInterval = {
                if case .failed = next { return 6 }
                if case .skipped = next { return 2 }
                return 0.45
            }()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // 次の録音・処理が始まっていたら消さない。
                if case .done = self.stage { self.setStage(.idle) }
                if case .failed = self.stage { self.setStage(.idle) }
                if case .skipped = self.stage { self.setStage(.idle) }
            }
            stageHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        default:
            stopProcessingTimer()
        }
    }

    private func startProcessingTimer() {
        guard processingTimer == nil else { return }
        processingStartedAt = Date()
        processingElapsed = 0
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let startedAt = VoiceCoordinator.shared.processingStartedAt else { return }
                VoiceCoordinator.shared.processingElapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopProcessingTimer() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingStartedAt = nil
    }

    private func teardownRecording() {
        watchdog.stop()
        tickTimer?.invalidate()
        tickTimer = nil

        // ⚠️ 速報の後始末は待たない。挿入までの体感を 1 ミリ秒も伸ばさない。
        if realtime.isRunning {
            let realtime = self.realtime
            Task { await realtime.stop() }
        }
    }

    private func tick() {
        guard state == .recording, let startedAt = recordingStartedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        // 最終的な安全弁。
        if elapsed >= AppSettings.shared.maxRecordingSeconds {
            Notifier.shared.warn("\(Int(AppSettings.shared.maxRecordingSeconds / 60)) 分を超えたため安全弁で停止しました。", notify: true)
            stopAndProcess()
        }
    }

    private func consume(level value: Float) {
        guard state == .recording else { return }
        level = value
        maxLevelDuringRecording = max(maxLevelDuringRecording, value)
        // ⚠️ 無音停止を OFF にしていても feed は続ける。
        //    「一度でも声を検出したか」の判定に使っており、止めるとまるごと破棄される。
        watchdog.feed(level: value)
    }

    // MARK: 再挿入

    /// 履歴やメニューバーから、既にあるテキストをもう一度カーソル位置に入れる。
    /// 自分のウィンドウが前面にいると自分に貼ってしまうので、先に隠して前のアプリに戻す。
    func reinsert(_ text: String) {
        guard !text.isEmpty else { return }
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do {
                try TextInserter.insert(text, method: AppSettings.shared.insertionMethod)
            } catch {
                Notifier.shared.error(error.localizedDescription)
            }
        }
    }

    // MARK: パイプライン

    private struct PipelineConfig {
        var transcription: TranscriptionConfig
        var format: FormatConfig
        var formattingEnabled: Bool
        var fillerRemovalEnabled: Bool
        var insertionMethod: InsertionMethod
        var lineBreakMode: LineBreakMode
        var historyEnabled: Bool
    }

    private func snapshotConfig() -> PipelineConfig {
        let settings = AppSettings.shared
        let dictionary = LocalDictionaryStore.shared
        // ⚠️ OpenAI のキーは、OpenAI を選んでいるところにだけ渡す。
        //    選んでいない経路にキーが渡らなければ、実装の取り違えがあっても外へ送れない。
        let openAIKey = Keychain.read(.openAIKey)
        return PipelineConfig(
            transcription: TranscriptionConfig(
                engine: settings.transcriptionEngine,
                whisperPrompt: dictionary.whisperPrompt(limit: settings.dictionaryPromptTerms),
                openAITranscribeModel: settings.openAITranscribeModel,
                openAIKey: settings.transcriptionEngine == .openai ? openAIKey : nil
            ),
            format: FormatConfig(
                provider: settings.formatProvider,
                ollamaURL: settings.ollamaGenerateURL,
                ollamaTagsURL: settings.ollamaTagsURL,
                model: settings.formatModel,
                openAIModel: settings.openAIFormatModel,
                openAIKey: settings.formatProvider == .openai ? openAIKey : nil,
                terms: dictionary.formatTerms
            ),
            formattingEnabled: settings.formattingEnabled,
            fillerRemovalEnabled: settings.fillerRemovalEnabled,
            insertionMethod: settings.insertionMethod,
            lineBreakMode: settings.lineBreakMode,
            historyEnabled: settings.historyEnabled
        )
    }

    private func runPipeline(
        wav: Data,
        duration: TimeInterval,
        focus: FocusInfo,
        stoppedAt: Date,
        config: PipelineConfig
    ) async {
        defer { processingCount = max(0, processingCount - 1) }

        let durationMs = Int(duration * 1000)

        // ① 文字起こし（設定で選んだエンジン）
        let transcription: TranscriptionResult
        do {
            transcription = try await TranscriptionService.shared.transcribe(
                wav: wav, duration: duration, config: config.transcription
            )
        } catch {
            // ⚠️ 「喋ったのに何も残らなかった」を避けるため、直近の 1 件だけメモリに持つ。
            failedRecording = FailedRecording(
                wav: wav, duration: duration, appName: focus.appName, appBundleID: focus.appBundleID
            )
            hasFailedRecording = true
            transcriptionOK = false
            setStage(.failed("文字起こしに失敗。メニューバーからやり直せます"),
                     destination: .transcriptionSettings)
            Notifier.shared.error("\(error.localizedDescription)\nメニューバーの「直前の録音をやり直す」から、もう一度試せます。")
            Notifier.shared.playErrorSound()
            return
        }
        transcriptionOK = true
        lastEngine = transcription.engine
        Notifier.shared.info("文字起こし完了（\(transcription.engine)）: \(transcription.text.prefix(40))")

        let rawText = transcription.text
        // 内蔵エンジンは、短い録音が日本語でないと分かった時点で文字起こしをやめて空を返す。
        // 喋っていないだけなので、失敗ではなく「何も挿入していない」として扱う。
        if rawText.isEmpty, let probability = transcription.japaneseProbability,
           probability < HallucinationFilter.japaneseThreshold {
            setStage(.skipped("何も挿入していません"))
            Notifier.shared.info(String(format: "日本語確率 %.3f のため文字起こしをしませんでした（喋っていない録音の可能性）", probability))
            return
        }
        guard !rawText.isEmpty else {
            setStage(.failed("文字起こしの結果が空でした"))
            Notifier.shared.info("文字起こしの結果が空でした。何も挿入していません。")
            return
        }

        // ② ハルシネーションなら整形も挿入もしない。
        // ⚠️ 履歴にも残さない。喋っていない「ご視聴ありがとうございました」が履歴に混ざると邪魔なので。
        switch HallucinationFilter.judge(
            text: rawText,
            japaneseProbability: transcription.japaneseProbability,
            prompt: config.transcription.whisperPrompt,
            duration: duration
        ) {
        case .ok:
            break
        case .notJapanese(let probability):
            setStage(.skipped("何も挿入していません"))
            Notifier.shared.info(String(
                format: "日本語確率 %.3f のため破棄しました（喋っていない録音の可能性）: %@",
                probability, String(rawText.prefix(40))
            ))
            return
        case .knownPhrase:
            setStage(.skipped("何も挿入していません"))
            Notifier.shared.info("whisper の定番フレーズと一致したため破棄しました: \(rawText.prefix(40))")
            return
        case .promptEcho(let ratio):
            setStage(.skipped("何も挿入していません"))
            Notifier.shared.info(String(
                format: "認識ヒントのエコー（一致率 %.0f%%）のため破棄しました: %@",
                ratio * 100, String(rawText.prefix(40))
            ))
            return
        }

        if config.formattingEnabled, let model = await formatModelName(config.format) {
            setStage(.formatting(model: model))
        }

        // ③ 整形（正規表現 → LLM → 辞書置換）
        let (text, formatModel) = await formatPipeline(rawText, duration: duration, config: config)
        guard !text.isEmpty else {
            setStage(.failed("整形結果が空でした"))
            Notifier.shared.info("整形結果が空でした。何も挿入していません。")
            return
        }

        // ④ 挿入
        setStage(.inserting)
        var inserted = true
        do {
            try TextInserter.insert(text, method: config.insertionMethod)
            lastInsertedText = text
        } catch {
            inserted = false
            setStage(.failed(error.localizedDescription))
            Notifier.shared.error(error.localizedDescription)
            Notifier.shared.playErrorSound()
        }

        let latencyMs = Int(Date().timeIntervalSince(stoppedAt) * 1000)
        lastLatencyMs = latencyMs
        Notifier.shared.info(String(
            format: "挿入%@ %d ms / %@ / %@",
            inserted ? "完了" : "失敗", latencyMs, transcription.engine, formatModel
        ))
        if inserted {
            setStage(.done(text: text, engine: transcription.engine, latencyMs: latencyMs))
        }

        // ⑤ 履歴に追記（この Mac のファイルだけ。失敗しても挿入は成功済み）
        // ⚠️ 「履歴を残さない」がオンのときは 1 件も書かない。
        guard config.historyEnabled else { return }
        LocalHistoryStore.shared.append(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            rawText: rawText,
            text: text,
            engine: transcription.engine,
            formatModel: formatModel,
            durationMs: durationMs,
            latencyMs: latencyMs,
            appName: focus.appName,
            appBundleID: focus.appBundleID
        ))
    }

    /// 整形に使われるモデルの名前。整形しないときは nil。
    private func formatModelName(_ config: FormatConfig) async -> String? {
        switch await FormatService.shared.resolvedProvider(config) {
        case .ollama: return config.model
        case .openai: return config.openAIModel
        case .none, .auto: return nil
        }
    }

    // MARK: 失敗した録音のやり直し

    /// 文字起こしに失敗した直近の録音を、もう一度パイプラインに通す。
    /// ⚠️ 挿入先は「いまフォーカスされているアプリ」ではなくクリップボード。
    ///    失敗から時間が経っていて、別の場所にカーソルがあるかもしれないため。
    func retryFailedRecording() {
        guard let failed = failedRecording else { return }
        failedRecording = nil
        hasFailedRecording = false
        processingCount += 1
        setStage(.transcribing)
        let config = snapshotConfig()
        let startedAt = Date()
        Task {
            defer { processingCount = max(0, processingCount - 1) }
            let transcription: TranscriptionResult
            do {
                transcription = try await TranscriptionService.shared.transcribe(
                    wav: failed.wav, duration: failed.duration, config: config.transcription
                )
            } catch {
                // もう一度やり直せるように戻す。
                failedRecording = failed
                hasFailedRecording = true
                transcriptionOK = false
                setStage(.failed("文字起こしに失敗しました"), destination: .transcriptionSettings)
                Notifier.shared.error(error.localizedDescription)
                Notifier.shared.playErrorSound()
                return
            }
            transcriptionOK = true

            guard HallucinationFilter.judge(
                text: transcription.text,
                japaneseProbability: transcription.japaneseProbability,
                prompt: config.transcription.whisperPrompt,
                duration: failed.duration
            ) == .ok else {
                setStage(.skipped("何も入っていませんでした"))
                Notifier.shared.info("やり直しの結果がハルシネーションだったため破棄しました: \(transcription.text.prefix(40))")
                return
            }

            let (text, formatModel) = await formatPipeline(transcription.text, duration: failed.duration, config: config)
            guard !text.isEmpty else {
                setStage(.failed("整形結果が空でした"))
                return
            }

            TextInserter.copyToPasteboard(text)
            lastInsertedText = text
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            setStage(.done(text: text, engine: transcription.engine, latencyMs: latencyMs))
            Notifier.shared.info("直前の録音を文字起こししてクリップボードに入れました。")
            if config.historyEnabled {
                LocalHistoryStore.shared.append(HistoryRecord(
                    id: UUID().uuidString,
                    createdAt: Date(),
                    rawText: transcription.text,
                    text: text,
                    engine: transcription.engine,
                    formatModel: formatModel,
                    durationMs: Int(failed.duration * 1000),
                    latencyMs: latencyMs,
                    appName: failed.appName,
                    appBundleID: failed.appBundleID
                ))
            }
        }
    }

    // MARK: 音声コマンド

    /// 文字起こし → 解釈（パターン照合 → LLM）→ ウィンドウ操作。
    ///
    /// ⚠️ 整形 LLM・フィラー除去・辞書置換は通さない（速さ優先。整形がアプリ名を書き換えると照合が壊れる）。
    /// ⚠️ 履歴に残さない。失敗してもやり直し用に持たない（届かなかったコマンドを後から実行しても意味がない）。
    /// ⚠️ `lastInsertedText` を更新しない（メニューバーの「再挿入」にコマンド文が出ないように）。
    private func runCommandPipeline(
        wav: Data,
        duration: TimeInterval,
        frontmost: NSRunningApplication?,
        stoppedAt: Date,
        config: PipelineConfig
    ) async {
        defer { processingCount = max(0, processingCount - 1) }

        // ① 文字起こし。アプリの別名を認識ヒントに足す（聞き落としを減らす）。
        var transcriptionConfig = config.transcription
        transcriptionConfig.checkLanguage = false
        let aliasTerms = AppAliasStore.shared.promptTerms
        if !aliasTerms.isEmpty {
            transcriptionConfig.whisperPrompt = [aliasTerms, transcriptionConfig.whisperPrompt]
                .filter { !$0.isEmpty }.joined(separator: "、")
        }

        let transcription: TranscriptionResult
        do {
            transcription = try await TranscriptionService.shared.transcribe(
                wav: wav, duration: duration, config: transcriptionConfig
            )
        } catch {
            transcriptionOK = false
            setStage(.failed("文字起こしに失敗しました"), destination: .transcriptionSettings)
            Notifier.shared.error("コマンドの文字起こしに失敗しました: \(error.localizedDescription)")
            Notifier.shared.playErrorSound()
            return
        }
        transcriptionOK = true

        let heard = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ 言語確率は渡さない。コマンドは 3 秒以下が普通で「Slack」のような英単語だけのこともあり、
        //    日本語確率の判定に巻き込まれる。定番フレーズとプロンプトエコーだけを弾く。
        guard !heard.isEmpty,
              HallucinationFilter.judge(
                  text: heard, japaneseProbability: nil,
                  prompt: transcriptionConfig.whisperPrompt, duration: duration
              ) == .ok
        else {
            setStage(.skipped("コマンドを聞き取れませんでした"))
            Notifier.shared.info("コマンド: 聞き取れませんでした（\(heard.prefix(40))）")
            return
        }

        // ② 解釈。パターン照合 → 外れたら LLM。
        var commands: [WindowCommand] = []
        var how = "照合"
        // ⚠️ LLM は整形と同じプロバイダに従う。選んでいない側の接続先は渡さない
        //    （解釈側は「Ollama → 失敗したら OpenAI」の順に試すので、渡さなければ切り替わらない）。
        //    整形しない設定のときは、パターン照合だけで動く。
        let provider = await FormatService.shared.resolvedProvider(config.format)
        let llmEnabled = AppSettings.shared.commandLLMFallbackEnabled && (provider == .ollama || provider == .openai)
        let llmConfig = CommandInterpreterConfig(
            ollamaURL: provider == .ollama ? config.format.ollamaURL : nil,
            model: config.format.model,
            openAIModel: config.format.openAIModel,
            openAIKey: provider == .openai ? config.format.openAIKey : nil
        )
        let llmModel = provider == .openai ? config.format.openAIModel : config.format.model
        switch CommandParser.analyze(heard, candidates: AppAliasStore.shared.candidates()) {
        case .commands(let parsed):
            commands = parsed

        case .needsTarget(let command, let spokenName):
            // 操作は分かっている。アプリの呼び名だけを LLM に聞く。
            guard llmEnabled else { break }
            setStage(.formatting(model: llmModel))
            guard let resolved = await CommandInterpreter.resolveApp(
                spokenName, targets: AppAliasStore.shared.targets(), config: llmConfig
            ) else {
                setStage(.failed("「\(spokenName)」がどのアプリか分かりません"))
                Notifier.shared.info("コマンド: 「\(heard)」→ アプリ名「\(spokenName)」を解決できませんでした")
                Notifier.shared.playErrorSound()
                return
            }
            var command = command
            command.target = resolved.target
            commands = [command]
            how = "照合 + 名前は \(resolved.model)（\(spokenName) → \(resolved.target.name)）"

        case .unknown:
            guard llmEnabled else { break }
            setStage(.formatting(model: llmModel))
            if let interpreted = await CommandInterpreter.interpret(
                heard, targets: AppAliasStore.shared.targets(), config: llmConfig
            ) {
                commands = interpreted.commands
                how = interpreted.model
            }
        }
        guard !commands.isEmpty else {
            setStage(.failed("解釈できませんでした: \(heard)"))
            Notifier.shared.info("コマンド: 「\(heard)」→ 解釈できませんでした")
            Notifier.shared.playErrorSound()
            return
        }

        // ③ 実行
        let summary = commands
            .map { "\($0.action.rawValue)(\($0.target?.name ?? "前面")\($0.display.map { " @\($0.rawValue)" } ?? ""))" }
            .joined(separator: ", ")
        do {
            let result = try await CommandExecutor.run(commands, frontmost: frontmost)
            let latencyMs = Int(Date().timeIntervalSince(stoppedAt) * 1000)
            setStage(.done(text: result, engine: transcription.engine, latencyMs: latencyMs))
            Notifier.shared.info("コマンド: 「\(heard)」→ \(summary) / \(how) / \(latencyMs) ms")
        } catch {
            setStage(.failed(error.localizedDescription))
            Notifier.shared.warn("コマンド: 「\(heard)」→ \(summary) / 失敗: \(error.localizedDescription)")
            Notifier.shared.playErrorSound()
        }
    }

    /// ⚠️ 並行して走るので、整形に使ったモデルは戻り値で返す（共有変数に置くと混ざる）。
    private func formatPipeline(
        _ rawText: String, duration: TimeInterval, config: PipelineConfig
    ) async -> (text: String, model: String) {
        // ① 正規表現でフィラー除去（0ms・確実）
        var text = config.fillerRemovalEnabled ? FillerRemover.remove(from: rawText) : rawText

        // ② LLM 整形（既定 ON。失敗しても止めない）
        var model = "none"
        if config.formattingEnabled {
            let result = await FormatService.shared.format(text, duration: duration, config: config.format)
            text = result.text
            model = result.model
        }

        // ③ ⚠️ 辞書の wrong_forms 置換は必ず LLM の「後」。LLM が壊した固有名詞を戻す最後の砦。
        text = LocalDictionaryStore.shared.applyReplacements(to: text)

        // ④ 読みやすさのための改行。⚠️ LLM に頼まず機械的に入れる（本文を書き換えられないため）。
        text = SentenceWrapper.wrap(text, mode: config.lineBreakMode)

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), model)
    }
}
