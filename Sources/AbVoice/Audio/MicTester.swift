import AVFoundation
import Foundation

/// 設定画面でマイクの音量を見るためだけの簡易モニタ。
///
/// ⚠️ 録音用の `AudioRecorder` とは別のエンジンを持つ。
///    「選んだマイクがちゃんと拾えているか」を喋る前に確かめられないと、
///    クラムシェルで無音のまま気づけないため。
@MainActor
final class MicTester: ObservableObject {
    static let shared = MicTester()

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var peak: Float = 0
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()

    private init() {}

    func toggle(inputDeviceUID: String?) {
        if isRunning {
            stop()
        } else {
            start(inputDeviceUID: inputDeviceUID)
        }
    }

    func start(inputDeviceUID: String?) {
        guard !isRunning else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = AudioRecorderError.microphoneDenied.localizedDescription
            Task { _ = await AudioRecorder.ensureMicrophoneAccess() }
            return
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)

        if case .fellBackToDefault(let uid) = AudioDeviceManager.apply(uid: inputDeviceUID, to: engine) {
            errorMessage = "選択中のマイク（\(AudioDeviceManager.name(forUID: uid) ?? uid)）が見つかりません。"
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = AudioRecorderError.noInputDevice.localizedDescription
            return
        }

        peak = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let value = Self.rms(of: buffer)
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.level = value
                self.peak = max(self.peak, value)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            errorMessage = nil
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = AudioRecorderError.engineFailed(error.localizedDescription).localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
    }

    /// 一度でも声とみなせる音量が入ったか。録音側の判定と同じ閾値にしてある。
    var heardSomething: Bool { peak >= 0.02 }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return 0 }
        var sum: Float = 0
        for i in 0..<frames { sum += data[0][i] * data[0][i] }
        return (sum / Float(frames)).squareRoot()
    }
}
