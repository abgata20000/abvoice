import CoreGraphics
import Foundation

/// 録音の操作モード。
enum RecordingMode: String, CaseIterable, Identifiable {
    /// 押した長さで tap / hold を自動判定する（既定）。
    case auto
    /// 常にトグル。もう一度押すまで録り続ける。
    case handsFree
    /// 常に押しっぱなし。離したら止まる。
    case pushToTalk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自動判定（短押しでトグル / 長押しで押しっぱなし）"
        case .handsFree: return "ハンズフリー（もう一度押すまで録る）"
        case .pushToTalk: return "押しっぱなし"
        }
    }
}

/// 録音インジケータを画面のどこに出すか。
///
/// ⚠️ 位置は選ばせるが、ドラッグでは動かせない。パネルがマウスイベントを取ると
///    その下にあるアプリを操作できなくなり、挿入先を邪魔してしまうため
///    （`ignoresMouseEvents = true` は外さない）。
enum IndicatorPosition: String, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft
    case bottomCenter
    case topRight
    case topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: return "右下（既定）"
        case .bottomLeft: return "左下"
        case .bottomCenter: return "下中央"
        case .topRight: return "右上"
        case .topLeft: return "左上"
        }
    }
}

/// テキストをどうやってカーソル位置に入れるか。
enum InsertionMethod: String, CaseIterable, Identifiable {
    /// クリップボード退避 → Cmd+V → 復元（既定）
    case paste
    /// CGEvent の Unicode 直接入力（ペーストが効かないアプリ用のフォールバック。短文限定）
    case unicode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paste: return "ペースト（Cmd+V を合成。既定）"
        case .unicode: return "直接入力（ペーストが効かないアプリ用。短文限定）"
        }
    }
}

/// どこで文字起こしするか。
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    /// この Mac の中（既定）。失敗してもクラウドには落とさない。
    case local
    /// OpenAI。届かなかったときは、モデルがあればこの Mac の中に落とす。
    case openai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "この Mac の中（音声は外に出ません）"
        case .openai: return "OpenAI（音声が OpenAI に送られます）"
        }
    }
}

/// この Mac の中で使う文字起こしモデルの選択肢。
enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case standard = "large-v3-v20240930_626MB"
    case light = "small_216MB"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "標準（約 626MB・精度優先）"
        case .light: return "軽量（約 216MB・メモリ 8GB の Mac 向け）"
        }
    }
}

/// 整形に使う LLM。
/// ⚠️ 選んでいないものへ自動で切り替えない（選んでいないのに送信・課金されるのを避ける）。
enum FormatProvider: String, CaseIterable, Identifiable {
    /// 起動時に 1 回 Ollama を探し、あれば使う。無ければ整形しない（既定）。
    case auto
    case ollama
    case openai
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自動（Ollama があれば使う）"
        case .ollama: return "Ollama"
        case .openai: return "OpenAI（テキストが OpenAI に送られます）"
        case .none: return "整形しない"
        }
    }
}

/// UserDefaults に永続化する設定。機密（API キー）はここに置かず Keychain に入れる。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: 文字起こし

    /// どこで文字起こしするか。
    /// ⚠️ `local` を選んだ人の音声が、失敗をきっかけに外へ出ることがあってはならない。
    @Published var transcriptionEngine: TranscriptionEngine {
        didSet { save(transcriptionEngine.rawValue, "transcriptionEngine") }
    }
    /// この Mac の中で使う文字起こしモデル。
    @Published var whisperModel: String { didSet { save(whisperModel, "whisperModel") } }
    /// 辞書の語を何語まで文字起こしのヒントに渡すか。0 なら渡さない（既定）。
    /// ⚠️ 渡した語数に比例して遅くなる（実測で 9 語につき約 0.5 秒）。
    ///    渡さなくても、辞書の置き換え（wrong_forms）は文字起こしの後に必ず効く。
    @Published var dictionaryPromptTerms: Int { didSet { save(dictionaryPromptTerms, "dictionaryPromptTerms") } }
    @Published var openAITranscribeModel: String { didSet { save(openAITranscribeModel, "openAITranscribeModel") } }

    // MARK: 整形 LLM

    @Published var formatProvider: FormatProvider { didSet { save(formatProvider.rawValue, "formatProvider") } }
    @Published var ollamaBaseURL: String { didSet { save(ollamaBaseURL, "ollamaBaseURL") } }
    @Published var formatModel: String { didSet { save(formatModel, "formatModel") } }
    @Published var openAIFormatModel: String { didSet { save(openAIFormatModel, "openAIFormatModel") } }

    // MARK: ホットキー

    /// 録音のトグルキー。既定は ⌃⌥Space。初回の設定で本人に決めてもらう。
    @Published var hotKeyCode: Int { didSet { save(hotKeyCode, "hotKeyCode") } }
    /// ホットキーに要求する修飾キー（CGEventFlags の raw 値。0 = 修飾なし）。
    @Published var hotKeyModifiers: UInt64 { didSet { save(Int(bitPattern: UInt(hotKeyModifiers)), "hotKeyModifiers") } }

    // MARK: 音声コマンド

    /// OFF のときはコマンドキーを横取りせず、他アプリにそのまま流す。
    @Published var commandsEnabled: Bool { didSet { save(commandsEnabled, "commandsEnabled") } }
    /// コマンド録音のキー。既定は ⌃⌥⌘Space。
    @Published var commandHotKeyCode: Int { didSet { save(commandHotKeyCode, "commandHotKeyCode") } }
    @Published var commandHotKeyModifiers: UInt64 {
        didSet { save(Int(bitPattern: UInt(commandHotKeyModifiers)), "commandHotKeyModifiers") }
    }
    /// パターン照合で解釈できなかったとき LLM に聞くか。
    @Published var commandLLMFallbackEnabled: Bool {
        didSet { save(commandLLMFallbackEnabled, "commandLLMFallbackEnabled") }
    }

    // MARK: 録音

    @Published var recordingMode: RecordingMode { didSet { save(recordingMode.rawValue, "recordingMode") } }
    /// 使うマイクの CoreAudio UID。nil / 空ならシステム既定。
    /// ⚠️ AudioDeviceID ではなく UID を保存する（再接続や再起動で ID は変わる）。
    @Published var inputDeviceUID: String? {
        didSet {
            if let inputDeviceUID, !inputDeviceUID.isEmpty {
                save(inputDeviceUID, "inputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
            }
        }
    }
    /// 止め忘れ防止の無音停止。喋り出しを検出した後にだけ働く。
    @Published var silenceStopEnabled: Bool { didSet { save(silenceStopEnabled, "silenceStopEnabled") } }
    @Published var silenceStopSeconds: Double { didSet { save(silenceStopSeconds, "silenceStopSeconds") } }
    /// 最終的な安全弁。
    @Published var maxRecordingSeconds: Double { didSet { save(maxRecordingSeconds, "maxRecordingSeconds") } }
    /// 開始・停止を音で知らせる（止まったことに気づかず喋り続ける事故を防ぐ）。
    @Published var soundFeedbackEnabled: Bool { didSet { save(soundFeedbackEnabled, "soundFeedbackEnabled") } }
    /// 録音インジケータを出す場所。
    @Published var indicatorPosition: IndicatorPosition {
        didSet { save(indicatorPosition.rawValue, "indicatorPosition") }
    }
    /// 喋っている間、オンデバイス認識の速報をインジケータに出す。
    /// ⚠️ 速報は表示だけ。挿入には使わない（確定は今までどおり停止後 1 回）。
    /// ⚠️ 邪魔なとき・不安定なときに切れる逃げ道として必ず残す。
    @Published var realtimePreviewEnabled: Bool { didSet { save(realtimePreviewEnabled, "realtimePreviewEnabled") } }

    // MARK: 整形

    @Published var formattingEnabled: Bool { didSet { save(formattingEnabled, "formattingEnabled") } }
    /// 文の区切りで改行を入れるか。長い口述が 1 段落で出てくると読みにくいため。
    @Published var lineBreakMode: LineBreakMode { didSet { save(lineBreakMode.rawValue, "lineBreakMode") } }
    @Published var fillerRemovalEnabled: Bool { didSet { save(fillerRemovalEnabled, "fillerRemovalEnabled") } }

    // MARK: 挿入

    @Published var insertionMethod: InsertionMethod { didSet { save(insertionMethod.rawValue, "insertionMethod") } }

    // MARK: 履歴

    /// OFF にすると履歴を 1 件も書かない。
    @Published var historyEnabled: Bool { didSet { save(historyEnabled, "historyEnabled") } }
    /// 履歴を残す日数。0 なら無期限。
    @Published var historyRetentionDays: Int { didSet { save(historyRetentionDays, "historyRetentionDays") } }

    // MARK: 初回の設定

    @Published var onboardingCompleted: Bool { didSet { save(onboardingCompleted, "onboardingCompleted") } }

    private init() {
        // ⚠️ ここで self のプロパティを参照するとイニシャライザが通らないので、
        //    ローカルの UserDefaults を捕まえる。
        let store = UserDefaults.standard
        func str(_ key: String, _ fallback: String) -> String {
            store.string(forKey: key) ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        func num(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) as? Double ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            store.object(forKey: key) as? Int ?? fallback
        }

        transcriptionEngine = TranscriptionEngine(
            rawValue: str("transcriptionEngine", TranscriptionEngine.local.rawValue)
        ) ?? .local
        whisperModel = str("whisperModel", WhisperModelChoice.standard.rawValue)
        dictionaryPromptTerms = int("dictionaryPromptTerms", 0)
        openAITranscribeModel = str("openAITranscribeModel", "gpt-4o-transcribe")

        formatProvider = FormatProvider(rawValue: str("formatProvider", FormatProvider.auto.rawValue)) ?? .auto
        ollamaBaseURL = str("ollamaBaseURL", "http://localhost:11434")
        // ⚠️ 大きいモデルは固有名詞を壊す実測があるので、既定は小さいものにしている。
        formatModel = str("formatModel", "gemma3:4b")
        openAIFormatModel = str("openAIFormatModel", "gpt-4o-mini")

        // ⚠️ 既定は素の Mac で押せるものにする（リマップ前提のキーを既定にしない）。
        let controlOption = Int(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
        let controlOptionCommand = controlOption | Int(CGEventFlags.maskCommand.rawValue)
        hotKeyCode = int("hotKeyCode", 49) // kVK_Space
        hotKeyModifiers = UInt64(UInt(bitPattern: int("hotKeyModifiers", controlOption)))

        commandsEnabled = bool("commandsEnabled", true)
        commandHotKeyCode = int("commandHotKeyCode", 49) // kVK_Space
        commandHotKeyModifiers = UInt64(UInt(bitPattern: int("commandHotKeyModifiers", controlOptionCommand)))
        commandLLMFallbackEnabled = bool("commandLLMFallbackEnabled", true)

        recordingMode = RecordingMode(rawValue: str("recordingMode", RecordingMode.auto.rawValue)) ?? .auto
        inputDeviceUID = store.string(forKey: "inputDeviceUID")
        silenceStopEnabled = bool("silenceStopEnabled", true)
        silenceStopSeconds = num("silenceStopSeconds", 30)
        maxRecordingSeconds = num("maxRecordingSeconds", 600)
        soundFeedbackEnabled = bool("soundFeedbackEnabled", true)
        indicatorPosition = IndicatorPosition(
            rawValue: str("indicatorPosition", IndicatorPosition.bottomRight.rawValue)
        ) ?? .bottomRight
        realtimePreviewEnabled = bool("realtimePreviewEnabled", true)

        formattingEnabled = bool("formattingEnabled", true)
        lineBreakMode = LineBreakMode(rawValue: str("lineBreakMode", LineBreakMode.none.rawValue)) ?? .none
        fillerRemovalEnabled = bool("fillerRemovalEnabled", true)

        insertionMethod = InsertionMethod(rawValue: str("insertionMethod", InsertionMethod.paste.rawValue)) ?? .paste

        historyEnabled = bool("historyEnabled", true)
        historyRetentionDays = int("historyRetentionDays", 90)

        onboardingCompleted = bool("onboardingCompleted", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: 派生

    var ollamaTagsURL: URL? { URL(string: ollamaBaseURL.trimmingCharacters(in: .whitespaces) + "/api/tags") }
    var ollamaGenerateURL: URL? { URL(string: ollamaBaseURL.trimmingCharacters(in: .whitespaces) + "/api/generate") }
}
