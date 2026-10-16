import AVFoundation
import SwiftUI

/// 初回の設定。初めて起動したとき（`onboardingCompleted == false`）だけ、メインウィンドウの代わりに出す。
/// 設定画面の「初回の設定をやり直す」から、もう一度出せる。
///
/// ⚠️ 許可は 1 つずつ求める（同時に 2 つのダイアログを出さない）。
/// ⚠️ Ollama と OpenAI はここに入れない。任意のものなので設定画面に置く（最初に使えるまでを遠ざけない）。
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, hotkey, tryIt

        var title: String {
            switch self {
            case .welcome: return "ようこそ"
            case .microphone: return "マイクの許可"
            case .accessibility: return "アクセシビリティの許可"
            case .model: return "文字起こしモデル"
            case .hotkey: return "ホットキー"
            case .tryIt: return "試してみる"
            }
        }
    }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var model = ModelManager.shared
    /// どこまで進んだか。⚠️ 途中でウィンドウを閉じても、次に開いたとき続きから出す。
    @AppStorage("onboardingStep") private var stepIndex = 0
    private var step: Step { Step(rawValue: stepIndex) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .microphone: MicrophoneStep(onGranted: next)
                    case .accessibility: AccessibilityStep(onGranted: next)
                    case .model: ModelStep()
                    case .hotkey: HotkeyStep()
                    case .tryIt: TryItStep()
                    }
                }
                .padding(28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var progressHeader: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Text("\(step.rawValue + 1) / \(Step.allCases.count)  \(step.title)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if step != .welcome {
                Button("戻る") { back() }
            }
            if step == .tryIt {
                Button("はじめる") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .welcome ? "はじめに設定する" : "次へ") { next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        stepIndex = following.rawValue
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        stepIndex = previous.rawValue
    }

    private func finish() {
        settings.onboardingCompleted = true
        // やり直したときは最初から出す。
        stepIndex = 0
        Notifier.shared.info("初回の設定を終えました")
        // 起動時には求めずにおいた通知の許可を、ここで求める。
        Notifier.shared.requestNotificationAuthorization()
    }
}

// MARK: - 1. ようこそ

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AbVoice Local へようこそ").font(.title2.bold())
            Text("""
            ホットキーを押して喋ると、文字にしてカーソルの位置に入れます。
            文字起こしはこの Mac の中で行います。
            メール・チャット・メモなど、文字を入力できる場所ならどこでも使えます。
            """)
            Label("音声はこの Mac の外に出ません", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.green)
            Text("設定で OpenAI を選んだときだけ、音声やテキストが OpenAI に送られます。選ばなければ何も送りません。")
                .font(.caption).foregroundStyle(.secondary)
            Text("このあと、許可を 2 つと、文字起こしモデルの取得、ホットキーを決めます。3 分ほどで終わります。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 2. マイク

private struct MicrophoneStep: View {
    let onGranted: () -> Void
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("マイクの使用を許可してください").font(.title3.bold())
            Text("喋った声を録音するために使います。録音するのは、ホットキーを押している間だけです。")

            switch status {
            case .authorized:
                Label("許可されています", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("マイクを許可する") { request() }
                    .controlSize(.large)
                Text("ボタンを押すと、macOS の確認が出ます。「許可」を押してください。")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                Label("許可されていません", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("""
                以前に「許可しない」を選んだ場合は、ここからは確認が出ません。\
                システム設定の「プライバシーとセキュリティ → マイク」で AbVoice Local をオンにしてください。
                """)
                    .font(.callout)
                HStack {
                    Button("システム設定を開く") { Permissions.openMicrophoneSettings() }
                    Button("確認し直す") { status = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
            }
        }
        .onAppear { status = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private func request() {
        Task {
            _ = await AudioRecorder.ensureMicrophoneAccess()
            status = AVCaptureDevice.authorizationStatus(for: .audio)
            // 許可されたら自動で次へ。
            if status == .authorized { onGranted() }
        }
    }
}

// MARK: - 3. アクセシビリティ

private struct AccessibilityStep: View {
    let onGranted: () -> Void
    @State private var trusted = Permissions.isAccessibilityTrusted
    /// 許可を待つ間だけ 1 秒ごとに確かめる。
    /// ⚠️ macOS は許可されたことを知らせてくれないので、この手順の間だけは見に行くしかない。
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("アクセシビリティを許可してください").font(.title3.bold())
            Text("ホットキーを受け取ることと、文字をカーソルの位置に入れることに使います。")

            if trusted {
                Label("許可されています", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("システム設定を開く") {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 6) {
                    Text("開いた画面でやること").font(.callout.bold())
                    Text("1. 一覧の中から「AbVoice Local」を探す（無ければ左下の「＋」で、アプリケーションの中から追加する）")
                    Text("2. 右のスイッチをオンにする")
                    Text("3. この画面に戻る（許可されると自動で次へ進みます）")
                }
                .font(.callout)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("許可を待っています…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: startWatching)
        .onDisappear(perform: stopWatching)
    }

    private func startWatching() {
        guard !Permissions.isAccessibilityTrusted else {
            trusted = true
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard Permissions.isAccessibilityTrusted else { return }
                trusted = true
                stopWatching()
                // ⚠️ 許可しただけではホットキーの監視は始まらない。ここで繋ぎ直す。
                VoiceCoordinator.shared.startHotkey()
                onGranted()
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 4. 文字起こしモデル

private struct ModelStep: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = ModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文字起こしモデルを取得します").font(.title3.bold())
            Text("文字起こしに使うモデルを、1 度だけインターネットから取得します。取得したモデルはこの Mac に保存され、以後はインターネットが無くても使えます。")

            Picker("モデル", selection: Binding(
                get: { settings.whisperModel },
                set: { newValue in
                    settings.whisperModel = newValue
                    Task { await model.prepare(variant: newValue) }
                }
            )) {
                ForEach(WhisperModelChoice.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            .disabled(isBusy)
            Text("迷ったら「標準」を選んでください。メモリが 8GB の Mac は「軽量」がおすすめです。")
                .font(.caption).foregroundStyle(.secondary)

            switch model.status {
            case .notDownloaded, .failed:
                Button("取得する") { Task { await model.downloadAndPrepare(variant: settings.whisperModel) } }
                    .controlSize(.large)
                if case .failed(let reason) = model.status {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("取得中 \(Int(fraction * 100))%").monospacedDigit() }
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("この Mac 向けに準備しています。取得した直後は数分かかります。")
                }
            case .ready:
                Label("使えます", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            if isBusy {
                Text("取得と準備は裏で続きます。「次へ」で先に進んでかまいません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isBusy: Bool {
        switch model.status {
        case .downloading, .preparing: return true
        default: return false
        }
    }
}

// MARK: - 5. ホットキー

private struct HotkeyStep: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @State private var capturing: Target?
    @State private var message: String?

    enum Target { case dictation, command }

    /// 候補。⚠️ リマップなしの素の Mac で押せるもの。`⌥Space` は他のアプリがよく使っているので避けた。
    private static let dictationCandidate = (code: 49, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
    private static let commandCandidate = (
        code: 49,
        modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ホットキーを決めます").font(.title3.bold())
            Text("押すと録音が始まり、もう一度押すと文字になって入ります。ほかのアプリで使っていないキーを選んでください。")

            row(
                title: "口述（喋って文字を入れる）",
                code: settings.hotKeyCode, modifiers: settings.hotKeyModifiers,
                target: .dictation, candidate: Self.dictationCandidate
            )
            row(
                title: "音声コマンド（喋ってウィンドウを動かす）",
                code: settings.commandHotKeyCode, modifiers: settings.commandHotKeyModifiers,
                target: .command, candidate: Self.commandCandidate
            )
            Text("音声コマンドは、押している間だけ聞き、離したら実行します（例:「Slack を左半分」）。使わなければそのままで構いません。")
                .font(.caption).foregroundStyle(.secondary)

            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if !coordinator.hotkeyActive {
                Label("アクセシビリティが許可されていないため、キーを記録できません。前の手順に戻って許可してください。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear {
            if capturing != nil { coordinator.cancelHotkeyCapture() }
        }
    }

    private func row(
        title: String, code: Int, modifiers: UInt64, target: Target, candidate: (code: Int, modifiers: UInt64)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.bold())
            HStack(spacing: 10) {
                Text(KeyCodeNames.name(for: code, modifiers: modifiers))
                    .font(.title3.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(capturing == target ? "キーを押してください…" : "キーを記録") { toggleCapture(target) }
                    .disabled(!coordinator.hotkeyActive || (capturing != nil && capturing != target))
                Button("\(KeyCodeNames.name(for: candidate.code, modifiers: candidate.modifiers)) を使う") {
                    apply(target, code: candidate.code, modifiers: candidate.modifiers)
                }
                .controlSize(.small)
                .disabled(capturing != nil)
            }
        }
    }

    private func toggleCapture(_ target: Target) {
        if capturing != nil {
            coordinator.cancelHotkeyCapture()
            capturing = nil
            return
        }
        capturing = target
        message = nil
        coordinator.beginHotkeyCapture { code, modifiers in
            capturing = nil
            apply(target, code: code, modifiers: modifiers)
        }
    }

    private func apply(_ target: Target, code: Int, modifiers: UInt64) {
        // ⚠️ 口述とコマンドに同じ組み合わせは登録させない（どちらの録音か決められなくなる）。
        switch target {
        case .dictation:
            guard !(code == settings.commandHotKeyCode && modifiers == settings.commandHotKeyModifiers) else {
                message = "音声コマンドと同じ組み合わせは使えません。"
                return
            }
            settings.hotKeyCode = code
            settings.hotKeyModifiers = modifiers
        case .command:
            guard !(code == settings.hotKeyCode && modifiers == settings.hotKeyModifiers) else {
                message = "口述と同じ組み合わせは使えません。"
                return
            }
            settings.commandHotKeyCode = code
            settings.commandHotKeyModifiers = modifiers
        }
        message = nil
        coordinator.applyHotkeySettings()
    }
}

// MARK: - 6. 試してみる

private struct TryItStep: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var model = ModelManager.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("試しに喋ってみましょう").font(.title3.bold())
            Text("下の欄をクリックしてから \(hotkeyName) を押し、「明日の会議は十時からです」と喋って、もう一度 \(hotkeyName) を押してください。")

            if model.status != .ready {
                Label(model.statusText, systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.orange)
            }

            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .frame(height: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if !text.isEmpty {
                Label("入りました。これで準備は完了です。", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("うまくいかないとき").font(.callout.bold())
                Text("・何も起きない → アクセシビリティの許可がオンになっているか確かめる")
                Text("・「声が入っていません」と出る → 設定の「マイク」で使うマイクを選ぶ")
                Text("・あとから辞書に「自分の名前」と「よく使う製品名」を入れると、聞き間違いが減ります")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { focused = true }
    }

    private var hotkeyName: String {
        KeyCodeNames.name(for: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
    }
}
