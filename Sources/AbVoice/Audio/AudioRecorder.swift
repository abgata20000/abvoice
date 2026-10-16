import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable
    case engineFailed(String)
    case inputDeviceMissing(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク で AbVoice を許可してください。"
        case .noInputDevice:
            return "入力デバイスが見つかりません。"
        case .converterUnavailable:
            return "音声フォーマットの変換を準備できませんでした。"
        case .engineFailed(let detail):
            return "録音を開始できませんでした: \(detail)"
        case .inputDeviceMissing(let name):
            return "選択中のマイク（\(name)）が見つかりません。システム既定のマイクで録音します。"
        case .conversionFailed(let detail):
            return "音声の変換に失敗しました（\(detail)）。設定 > マイク で別のデバイスを試してください。"
        }
    }
}

/// ホットキーを押している間だけマイクを開く録音器。
/// 16kHz / mono / Int16 に変換しながら溜め、停止時に WAV を返す。
final class AudioRecorder {
    static let sampleRate = 16_000

    /// バッファごとの RMS レベル（0.0〜1.0 程度）。UI のレベルメーターと無音監視に使う。
    var onLevel: ((Float) -> Void)?
    /// 録音バッファのお裾分け。リアルタイム速報（`RealtimeTranscriber`）に渡すためだけにある。
    /// ⚠️ オーディオスレッドから呼ばれる。重い処理を書かない。
    /// ⚠️ 速報用に `AVAudioEngine` をもう 1 つ立てないためのフック（マイクの取り合いを避ける）。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    /// エンジンに割り当て済みの入力デバイス UID。変わったときだけ差し替える（毎回やると開始が遅くなる）。
    private var appliedDeviceUID: String??
    private var converter: AVAudioConverter?
    /// tap を張ったときのフォーマット。速報側が同じ音を変換するのに要る。
    private(set) var inputFormat: AVAudioFormat?
    /// 変換の入口。⚠️ **必ず 1ch**。理由は `makeMonoBuffer` のコメントを参照。
    private var monoFormat: AVAudioFormat?
    private let lock = NSLock()
    private var pcm = Data()
    private var running = false
    private var startedAt: Date?
    private var conversionError: String?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 直近の録音で変換エラーが出ていたらその内容。無音の原因を「声が入らなかった」と誤診しないために持つ。
    var lastConversionError: String? {
        lock.lock(); defer { lock.unlock() }
        return conversionError
    }

    /// マイク許可を（必要なら）求める。既に拒否されている場合は false。
    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// - Parameter inputDeviceUID: 使うマイクの UID。nil ならシステム既定。
    ///   ⚠️ クラムシェルだと内蔵マイクが死ぬので、ここで明示的に選べるようにしてある。
    func start(inputDeviceUID: String?) throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphoneDenied
        }

        // 前回の tap が残っていることがあるので必ず外してから張り直す。
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // デバイスの割り当ては format を読む前に済ませる。選択が変わっていないときは触らない。
        var missingDevice: String?
        if appliedDeviceUID != .some(inputDeviceUID) {
            switch AudioDeviceManager.apply(uid: inputDeviceUID, to: engine) {
            case .fellBackToDefault(let uid):
                missingDevice = AudioDeviceManager.name(forUID: uid) ?? uid
                appliedDeviceUID = .some(nil)
            case .applied, .systemDefault:
                appliedDeviceUID = .some(inputDeviceUID)
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        // ⚠️ チャンネル数とサンプルレートを AVAudioConverter に同時変換させない。
        //    ステレオのマイク（USB オーディオはほぼ 2ch）で無音になることがある。
        //    自前でモノラルに畳んでから、レート変換だけを AVAudioConverter に任せる。
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: monoFormat, to: outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        // リサンプラは状態を持つのでバッファ間で使い回す。
        self.monoFormat = monoFormat
        self.converter = converter
        self.inputFormat = inputFormat

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        running = true
        startedAt = Date()
        conversionError = nil
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); running = false; lock.unlock()
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }

        // ⚠️ 録音は既定デバイスで続行する。黙って別のマイクを使うと気づけないので知らせる。
        if let missingDevice {
            Task { @MainActor in
                Notifier.shared.warn(
                    AudioRecorderError.inputDeviceMissing(missingDevice).localizedDescription,
                    notify: true
                )
            }
        }
    }

    /// 録音を止め、WAV データと発話長を返す。
    @discardableResult
    func stop() -> (wav: Data, duration: TimeInterval)? {
        guard isRunning else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        running = false
        let samples = pcm
        let started = startedAt
        pcm = Data()
        startedAt = nil
        lock.unlock()

        converter = nil
        monoFormat = nil

        let duration = started.map { Date().timeIntervalSince($0) }
            ?? Double(samples.count / 2) / Double(Self.sampleRate)
        guard !samples.isEmpty else { return nil }
        return (WavEncoder.wav(pcm16: samples, sampleRate: Self.sampleRate), duration)
    }

    /// 録音内容を捨てて止める。
    func discard() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        running = false
        pcm = Data()
        startedAt = nil
        lock.unlock()
        converter = nil
        monoFormat = nil
    }

    // MARK: 内部

    private func handle(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        onLevel?(Self.rms(of: buffer))
        // ⚠️ 速報は「おまけ」。ここから先の録音の流れには一切影響させない。
        onBuffer?(buffer)

        guard let converter, let monoFormat,
              let mono = Self.makeMonoBuffer(from: buffer, format: monoFormat) else { return }

        let ratio = outputFormat.sampleRate / monoFormat.sampleRate
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

        if let error {
            lock.lock()
            if conversionError == nil { conversionError = error.localizedDescription }
            lock.unlock()
            return
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        let chunk = Data(bytes: channel[0], count: byteCount)

        lock.lock()
        if running { pcm.append(chunk) }
        lock.unlock()
    }

    /// 入力バッファを 1ch の Float32 に畳む。
    ///
    /// ⚠️ ここを AVAudioConverter に任せない。ステレオ + リサンプルを同時に指示すると
    ///    デバイスによっては黙って無音を返す（USB マイクはほぼ 2ch なので実害が大きい）。
    private static func makeMonoBuffer(from buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
                // 全チャンネルの平均を取る（片方のチャンネルが無音のマイクでも拾えるように）。
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

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let float = buffer.floatChannelData {
            var sum: Float = 0
            let data = float[0]
            for i in 0..<frames { sum += data[i] * data[i] }
            return (sum / Float(frames)).squareRoot()
        }
        if let int16 = buffer.int16ChannelData {
            var sum: Float = 0
            let data = int16[0]
            for i in 0..<frames {
                let v = Float(data[i]) / 32768.0
                sum += v * v
            }
            return (sum / Float(frames)).squareRoot()
        }
        return 0
    }
}
