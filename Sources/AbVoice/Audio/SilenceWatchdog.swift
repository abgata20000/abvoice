import Foundation

/// 止め忘れ防止のためだけの無音監視。
///
/// ⚠️ 「喋り終わりを検出して自動で止める」ものではない。
/// 考えながら数秒〜十数秒黙るのは普通なので、既定 30 秒まで待つ。
/// さらに **喋り出しを一度も検出していない間は作動しない**（考えてから話し始めても切らない）。
final class SilenceWatchdog {
    /// 無音がこの秒数続いたら停止。
    var threshold: TimeInterval
    /// 停止させたいときに呼ばれる。
    var onTimeout: (() -> Void)?

    /// 開始直後のこの時間でノイズフロアを測る。
    private let calibrationDuration: TimeInterval = 0.3
    /// ノイズフロアの何倍を「声」とみなすか。
    private let voiceFactor: Float = 3.0
    /// 静かすぎる環境でノイズフロアが 0 に張り付くのを防ぐ下限。
    /// ⚠️ 高くすると入力の小さい USB マイクで「声なし」と誤判定する（実測で 0.012 は高すぎた）。
    private let minimumVoiceLevel: Float = 0.004
    /// ノイズフロアがどれだけ上振れしても、この音量以上は必ず「声」とみなす上限。
    /// ⚠️ 計測窓に開始音・キー押下音・喋り出しが入るとノイズフロアが 0.012〜0.014 まで上振れし、
    ///    しきい値が約 0.04 になって普通の発話（0.01〜0.03）を声と判定しなくなる。
    ///    開始直後の一瞬だけ声と判定され、その 30 秒後に喋っている最中でも止まった（2026-09-04 / 09-08 実測）。
    ///    短い発話の peak の実測下限は 0.0155。
    private let maximumVoiceLevel: Float = 0.010

    private var startedAt: Date?
    private var calibrationSamples: [Float] = []
    /// 測定したノイズフロア。無音判定の基準として外からも使う。
    private(set) var noiseFloor: Float = 0
    private(set) var voiceThreshold: Float = 0
    private var lastVoiceAt: Date?
    /// 一度でも声を検出したか。無音のまま止まったときに幻聴テキストを挿入しない判断に使う。
    private(set) var didHearVoice = false
    private var fired = false

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    func start() {
        startedAt = Date()
        calibrationSamples = []
        noiseFloor = 0
        voiceThreshold = 0
        lastVoiceAt = nil
        didHearVoice = false
        fired = false
    }

    /// 録音側から RMS レベル（0.0〜1.0 程度）を渡す。
    func feed(level: Float) {
        guard let startedAt, !fired else { return }
        let now = Date()

        if now.timeIntervalSince(startedAt) < calibrationDuration {
            calibrationSamples.append(level)
            return
        }

        if voiceThreshold == 0 {
            let avg = calibrationSamples.isEmpty
                ? 0
                : calibrationSamples.reduce(0, +) / Float(calibrationSamples.count)
            noiseFloor = avg
            // 雑音が常に上限を超える部屋では無音停止が効かなくなるが、それは許容する
            // （止め忘れ防止のためだけの機能で、最長録音の安全弁が別にある。喋っている最中に切る方がずっと害が大きい）。
            voiceThreshold = min(max(avg * voiceFactor, minimumVoiceLevel), maximumVoiceLevel)
        }

        if level >= voiceThreshold {
            didHearVoice = true
            lastVoiceAt = now
            return
        }

        // ⚠️ 喋り出す前の沈黙では切らない。
        guard didHearVoice, let lastVoiceAt else { return }
        if now.timeIntervalSince(lastVoiceAt) >= threshold {
            fired = true
            onTimeout?()
        }
    }

    func stop() {
        startedAt = nil
        fired = true
    }
}
