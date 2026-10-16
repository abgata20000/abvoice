import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 録音中だけ動く「速報」の文字起こし。オンデバイス（macOS 26 の `SpeechTranscriber`）で、
/// 課金ゼロ・ネットワーク不要。
///
/// ⚠️⚠️ **速報は表示専用。挿入には絶対に使わない。**
///    リアルタイムに挿入すると確定時に差し替えが要り、その間にカーソルが動くと挿入先を壊す。
///    確定は今までどおり「停止 → whisper → 整形 → 辞書置換 → 1 回だけ挿入」で行う。
///
/// ⚠️ `AVAudioEngine` をここで作らない。`AudioRecorder` の tap から流してもらう
///    （エンジンを 2 つ立てるとマイクの取り合いになり、クラムシェル対策のデバイス指定も二重になる）。
@MainActor
final class RealtimeTranscriber: ObservableObject {
    /// 速報テキスト（確定 + 未確定）。有無の判定はこれを見る。
    @Published private(set) var text: String = ""
    /// 確定済みのぶん。インジケータでは薄く出す。
    @Published private(set) var confirmedText: String = ""
    /// まだ確定していないぶん ＝ **いま喋っているところ**。インジケータでは濃く出す。
    /// ⚠️ 認識が言い直すとここだけが書き換わる。
    @Published private(set) var volatileText: String = ""
    @Published private(set) var isRunning = false

    /// 速報の有無が変わったときに呼ばれる。インジケータの幅を変えるのに使う。
    var onPreviewVisibilityChanged: ((Bool) -> Void)?

    /// 様子を見る間隔。
    private static let clockInterval: TimeInterval = 2

    /// 未確定のまま溜めてよい長さ。これを超えたときだけ `finalize(through:)` を呼ぶ。
    ///
    /// ⚠️⚠️ **速報のために finalize を呼ばない。** 2 秒ごとに呼ぶと切れ目で数文字が脱落する
    ///    （実測: 「ラウンドメイト」→「ウン。メイト」、「そのまま渡せる」→「そのままてる」）。
    ///    `.progressiveTranscription` は未確定（volatile）の結果を 1 秒ごとに流してくれるので、
    ///    速報はそれで足りる（実測: 最初の速報 1.2 秒 / 81 秒流しても遅延も脱落も増えない）。
    ///    ここで finalize するのは、長丁場で未確定範囲が肥大するのを防ぐためだけ。
    private static let maxVolatileSeconds: TimeInterval = 120

    /// 確定を頼む位置を、供給済みの末尾からどれだけ手前にするか。
    /// ⚠️ 末尾ぴったりで確定させると単語の途中で切られる。少し残すと後ろの音を見て区切ってくれる。
    private static let finalizeLag: TimeInterval = 2

    /// 溜め込む速報の上限。長時間喋っても青天井にしない（表示は末尾だけ）。
    private static let maxTextLength = 4_000

    /// 変換と供給だけを持つ。⚠️ 録音の tap スレッドから触るので MainActor には置けない。
    private let pipe = BufferPipe()
    /// 実体は `Session`（macOS 26 限定の型なので `AnyObject` で持つ）。
    private var session: AnyObject?

    /// この Mac で速報を出せるか。
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    // MARK: 開始・供給・停止

    /// - Parameters:
    ///   - inputFormat: `AudioRecorder` の tap が流してくるフォーマット。
    ///   - contextualStrings: 認識のヒントに渡す固有名詞（辞書の見出し語）。
    func start(inputFormat: AVAudioFormat, contextualStrings: [String]) async {
        guard !isRunning, session == nil else { return }
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return }

        // ⚠️ 先に受け入れ態勢だけ作る。準備が終わるまでのバッファは pipe が溜めておいてくれるので、
        //    喋り出しの数百 ms を取りこぼさない。
        pipe.prepare()
        isRunning = true
        setText(confirmed: "", volatile: "")

        let locale = Locale(identifier: "ja-JP")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            await failStart("この Mac のオンデバイス認識が日本語に対応していないため速報は出しません。")
            return
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) else {
            await failStart("日本語のオンデバイスモデルが入っていないため速報は出しません。")
            return
        }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)

        // ⚠️ 効かなくても速報の精度が落ちるだけ。確定側（whisper + 辞書）で直るので止めない。
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: inputFormat
        ) else {
            await failStart("速報に使える音声フォーマットが見つからなかったため速報は出しません。")
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime)
        )

        do {
            try await analyzer.setContext(context)
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            await failStart("速報を開始できませんでした（\(error.localizedDescription)）。録音と挿入は今までどおり動きます。")
            return
        }

        // 途中で止められていたら後片付けして終わる。
        guard isRunning else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return
        }

        // 結果を読む。⚠️ volatile（未確定）は上書き、final（確定）は積み上げる。
        let collector = Task { [weak self] in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalized += piece
                        if finalized.count > Self.maxTextLength {
                            finalized = String(finalized.suffix(Self.maxTextLength))
                        }
                        self?.setText(confirmed: finalized, volatile: "")
                    } else {
                        self?.setText(confirmed: finalized, volatile: piece)
                    }
                }
            } catch {
                // 速報が落ちても録音は続く。黙って止める。
            }
        }

        // ⚠️⚠️ finalize は音声供給と **別タスク** から呼ぶこと。
        //    同じタスクで回すとデッドロックする（10 分待っても返らなかった。research.md）。
        let clock = Task { [pipe] in
            var lastMark: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.clockInterval))
                if Task.isCancelled { break }
                // 未確定が伸びすぎたときだけ畳む。⚠️ 呼ぶたびに切れ目で数文字を失う。
                let fed = pipe.fedSeconds
                guard fed - lastMark > Self.maxVolatileSeconds else { continue }
                // ⚠️ まだ流していない時刻まで finalize すると、その音声を待って返ってこない。
                //    実際に供給した長さより手前で頼む。
                let mark = fed - Self.finalizeLag
                lastMark = mark
                try? await analyzer.finalize(through: CMTime(seconds: mark, preferredTimescale: 600))
            }
        }

        session = Session(analyzer: analyzer, continuation: continuation, collector: collector, clock: clock)

        // 変換の準備ができた時点で、溜めておいた喋り出しも含めて流れ始める。
        pipe.configure(outputFormat: analyzerFormat) { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// 録音の tap から呼ぶ。⚠️ オーディオスレッドから来るので MainActor に触らない。
    ///
    /// ⚠️ 速報を使っていない間もここは呼ばれる。`start()` するまでは即座に捨てるので、
    ///    録音側は `onBuffer` を付け替えなくてよい（付け替えると tap スレッドとの競合になる）。
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        pipe.feed(buffer)
    }

    /// 速報を止める。⚠️ 呼び出し側は待たなくてよい（挿入の経路を遅らせない）。
    func stop() async {
        isRunning = false
        pipe.reset()
        guard #available(macOS 26.0, *), let session = session as? Session else {
            self.session = nil
            return
        }
        self.session = nil
        await session.finish()
    }

    // MARK: 内部

    private func setText(confirmed: String, volatile: String) {
        let wasVisible = !text.isEmpty
        confirmedText = confirmed
        volatileText = volatile
        text = confirmed + volatile
        if wasVisible != !text.isEmpty {
            onPreviewVisibilityChanged?(!text.isEmpty)
        }
    }

    /// 速報だけ諦める。⚠️ ここで録音まで止めたら本末転倒。
    private func failStart(_ message: String) async {
        isRunning = false
        session = nil
        pipe.reset()
        setText(confirmed: "", volatile: "")
        Notifier.shared.info("リアルタイム速報: \(message)")
    }

    /// 走っている解析一式。macOS 26 限定の型を抱えるためだけに分けてある。
    @available(macOS 26.0, *)
    private final class Session {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let collector: Task<Void, Never>
        let clock: Task<Void, Never>

        init(
            analyzer: SpeechAnalyzer,
            continuation: AsyncStream<AnalyzerInput>.Continuation,
            collector: Task<Void, Never>,
            clock: Task<Void, Never>
        ) {
            self.analyzer = analyzer
            self.continuation = continuation
            self.collector = collector
            self.clock = clock
        }

        func finish() async {
            clock.cancel()
            continuation.finish()
            // ⚠️ 速報はもう要らない。最後まで文字起こしするのを待たずに畳む
            //    （待つと停止が遅れ、そのぶん挿入までの体感が伸びる）。
            await analyzer.cancelAndFinishNow()
            collector.cancel()
        }
    }
}

/// 録音の tap から来たバッファを、解析器が食べられる形に変換して渡す係。
///
/// ⚠️ tap スレッドと MainActor の両方から触るのでロックで守る。
private final class BufferPipe: @unchecked Sendable {
    private let lock = NSLock()
    /// tap からの供給を受け付けるか。
    /// ⚠️ 速報が OFF のときにオーディオスレッドで無駄な変換をしないための門番。
    private var accepting = false
    private var converter: AVAudioConverter?
    /// 変換の入口。⚠️ **必ず 1ch**（理由は `foldToMono` のコメント）。
    private var monoFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var emit: ((AVAudioPCMBuffer) -> Void)?
    /// 解析器に渡した音声の総フレーム数。finalize をどこまで頼めるかの根拠にする。
    private var fedFrames: AVAudioFramePosition = 0
    /// 準備が終わるまでの取り置き。⚠️ 喋り出しを落とすと速報の頭が欠ける。
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0

    /// 取り置きの上限（秒）。これを超えたら古いものから捨てる。
    private static let maxPendingSeconds: Double = 2

    /// 解析器に渡した音声の長さ（秒）。
    var fedSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let outputFormat, outputFormat.sampleRate > 0 else { return 0 }
        return Double(fedFrames) / outputFormat.sampleRate
    }

    /// 変換先が決まったので、取り置きも含めて流し始める。
    ///
    /// ⚠️ 取り置きの吐き出しもロックの中で行う。外でやると、吐き出している最中に
    ///    tap から届いた新しいバッファが古いものを追い越し、解析器に順序違いの音声が入る。
    func configure(outputFormat: AVAudioFormat, emit: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.outputFormat = outputFormat
        self.emit = emit
        for buffer in pending { emitLocked(buffer) }
        pending = []
        pendingFrames = 0
    }

    /// 受け入れを始める。⚠️ 解析器の準備が終わる前に呼ぶ（喋り出しを取り置きするため）。
    func prepare() {
        reset()
        lock.lock()
        accepting = true
        lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let ready = emit != nil && outputFormat != nil
        let format = monoFormat ?? Self.makeMonoFormat(like: buffer.format)
        if monoFormat == nil { monoFormat = format }
        lock.unlock()

        guard let format, let mono = Self.foldToMono(buffer, format: format) else { return }

        if ready {
            convertAndEmit(mono: mono)
            return
        }

        lock.lock()
        pending.append(mono)
        pendingFrames += AVAudioFramePosition(mono.frameLength)
        let limit = AVAudioFramePosition(format.sampleRate * Self.maxPendingSeconds)
        while pendingFrames > limit, !pending.isEmpty {
            pendingFrames -= AVAudioFramePosition(pending.removeFirst().frameLength)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        accepting = false
        converter = nil
        monoFormat = nil
        outputFormat = nil
        emit = nil
        fedFrames = 0
        pending = []
        pendingFrames = 0
        lock.unlock()
    }

    // MARK: 内部

    private func convertAndEmit(mono: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        emitLocked(mono)
    }

    /// ⚠️ ロックを取った状態で呼ぶこと。供給の順序を守るため、変換から yield までを直列化している。
    private func emitLocked(_ mono: AVAudioPCMBuffer) {
        guard let outputFormat, let emit else { return }
        if converter == nil || converter?.inputFormat != mono.format {
            converter = AVAudioConverter(from: mono.format, to: outputFormat)
        }
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        // 速報が変換で落ちても録音は無傷。黙って捨てる。
        guard error == nil, out.frameLength > 0 else { return }

        fedFrames += AVAudioFramePosition(out.frameLength)
        emit(out)
    }

    private static func makeMonoFormat(like format: AVAudioFormat) -> AVAudioFormat? {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// 入力バッファを 1ch の Float32 に畳んで**新しいバッファ**にコピーする。
    ///
    /// ⚠️ チャンネル数とサンプルレートを `AVAudioConverter` に同時変換させない。
    ///    ステレオのマイク（USB オーディオはほぼ 2ch）で黙って無音になることがある
    ///    （`AudioRecorder` で踏んだのと同じ穴）。
    /// ⚠️ tap のバッファをそのまま溜めない。ここで必ずコピーを作る。
    private static func foldToMono(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData
        else { return nil }
        mono.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)
        let out = destination[0]

        if let source = buffer.floatChannelData {
            if channels == 1 {
                out.update(from: source[0], count: frames)
            } else {
                let scale = 1.0 / Float(channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += source[channel][frame] }
                    out[frame] = sum * scale
                }
            }
            return mono
        }

        if let source = buffer.int16ChannelData {
            let scale = 1.0 / (32768.0 * Float(channels))
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(source[channel][frame]) }
                out[frame] = sum * scale
            }
            return mono
        }

        return nil
    }
}
