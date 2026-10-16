import AppKit
import CoreGraphics
import Foundation

/// グローバルホットキーの監視。
///
/// Carbon の RegisterEventHotKey ではなく CGEventTap を使う。
/// どのみち Cmd+V の合成でアクセシビリティ権限が要るので、権限の要否で選ぶ理由がない。
///
/// ⚠️ キーを押した瞬間に録音を開始し、長押し判定は「停止方法」の決定にだけ使う。
///    こうすると長押し判定を入れても開始の遅延がゼロになる（喋り出しが切れない）。
/// ⚠️ キーリピートは無視する。押しっぱなしで録音が連続トグルする事故になる。
final class HotkeyMonitor {
    /// 押した瞬間に録音を始めたい。
    var onStart: (() -> Void)?
    /// コマンドキーが押された。音声コマンドとして録音を始めたい。
    var onStartCommand: (() -> Void)?
    /// 録音を止めて処理に回したい。⚠️ 口述・コマンド共用。用途は開始時に決まっている。
    var onStop: (() -> Void)?
    /// Escape。録音を破棄する。
    var onCancel: (() -> Void)?
    /// 録音中かどうかを問い合わせる。
    var isRecording: (() -> Bool)?
    /// 設定画面の「ホットキーを記録」用。次に押されたキーを 1 回だけ拾う。
    var onCapture: ((Int64, UInt64) -> Void)?

    /// tap / hold を分ける閾値。
    private let holdThreshold: TimeInterval = 0.3
    private static let escapeKeyCode: Int64 = 53
    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var keyCode: Int64 = 79
    private var requiredModifiers: CGEventFlags = []
    private var mode: RecordingMode = .auto

    /// 音声コマンド用のキー。無効のときは横取りせず他アプリに流す。
    private var commandEnabled = false
    private var commandKeyCode: Int64 = 79
    private var commandModifiers: CGEventFlags = .maskCommand

    /// いま押されているホットキーのキーコード。離したときの照合に使う。
    /// ⚠️ 離す側は修飾キーを見ない。`⌘Space` で Space より先に ⌘ を離すと keyUp の修飾キーが
    ///    一致しなくなり、押しっぱなし（PTT）の録音が止まらなくなるため。
    private var pressedKeyCode: Int64?

    /// このキー押下で録音を開始したか（＝離したときに止める判断をする対象か）。
    private var startedByCurrentPress = false
    /// このキー押下がコマンドキーだったか。
    private var startedAsCommand = false
    /// 長押しとして確定したか。
    private var isHold = false
    private var pressGeneration = 0

    private(set) var isCapturing = false

    // MARK: 設定

    func configure(keyCode: Int, modifiers: UInt64, mode: RecordingMode) {
        self.keyCode = Int64(keyCode)
        self.requiredModifiers = CGEventFlags(rawValue: modifiers).intersection(Self.modifierMask)
        self.mode = mode
    }

    func configureCommand(keyCode: Int, modifiers: UInt64, enabled: Bool) {
        commandKeyCode = Int64(keyCode)
        commandModifiers = CGEventFlags(rawValue: modifiers).intersection(Self.modifierMask)
        commandEnabled = enabled
    }

    /// 次に押されたキーを 1 回だけ拾って返す（設定画面のホットキー記録ボタン）。
    func beginCapture() { isCapturing = true }
    func cancelCapture() { isCapturing = false }

    // MARK: 開始・停止

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.isAccessibilityTrusted else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    var isActive: Bool { tap != nil }

    // MARK: イベント処理

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // タップが無効化されたら復帰させる（重い処理でタイムアウトすることがある）。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags.intersection(Self.modifierMask)

        // ホットキーの記録
        if isCapturing {
            guard type == .keyDown else { return nil }
            if repeated { return nil }
            isCapturing = false
            DispatchQueue.main.async { [weak self] in
                self?.onCapture?(code, flags.rawValue)
            }
            return nil // 記録中のキーは他アプリに流さない
        }

        // Escape は録音中だけ横取りする
        if code == Self.escapeKeyCode {
            guard type == .keyDown, isRecording?() == true else {
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return nil
        }

        if type == .keyUp {
            // 押したときに横取りしたキーだけを、離すときも横取りする。
            guard code == pressedKeyCode else { return Unmanaged.passUnretained(event) }
            pressedKeyCode = nil
            handleKeyUp()
            return nil
        }

        let isDictationKey = code == keyCode && flags == requiredModifiers
        let isCommandKey = commandEnabled && code == commandKeyCode && flags == commandModifiers
        guard isDictationKey || isCommandKey else {
            return Unmanaged.passUnretained(event)
        }

        // ⚠️ キーリピートは黙って捨てる（連続トグル事故の防止）
        if repeated { return nil }

        pressedKeyCode = code
        // 両方に当たることは無い（設定画面で同じ組み合わせを登録させない）が、念のため口述を優先する。
        handleKeyDown(isCommand: isCommandKey && !isDictationKey)
        return nil // ホットキー自体は他アプリに流さない
    }

    private func handleKeyDown(isCommand: Bool) {
        let recording = isRecording?() ?? false

        if recording {
            // 直前の押下で始めた録音を、離す前に押し直すことは（リピート除去済みなので）起きない。
            // ここに来るのは「トグルの 2 回目」。
            DispatchQueue.main.async { [weak self] in self?.onStop?() }
            startedByCurrentPress = false
            isHold = false
            return
        }

        // ★ 押した瞬間に開始する。tap / hold の判定は停止方法の決定にしか使わない。
        startedByCurrentPress = true
        // ⚠️ コマンドは録音モードに関係なく常に押しっぱなし（押している間だけ聞き、離したら実行）。
        //    短い指示を出すだけなので、止めるためにもう一度押させない。
        startedAsCommand = isCommand
        isHold = (mode == .pushToTalk) || isCommand
        pressGeneration += 1
        let generation = pressGeneration

        DispatchQueue.main.async { [weak self] in
            if isCommand { self?.onStartCommand?() } else { self?.onStart?() }
        }

        guard mode == .auto, !isCommand else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold) { [weak self] in
            guard let self, self.pressGeneration == generation, self.startedByCurrentPress else { return }
            // まだ離されていない = 長押し。離した時点で止める。
            self.isHold = true
        }
    }

    private func handleKeyUp() {
        pressGeneration += 1
        guard startedByCurrentPress else { return }

        if startedAsCommand {
            startedByCurrentPress = false
            startedAsCommand = false
            isHold = false
            DispatchQueue.main.async { [weak self] in self?.onStop?() }
            return
        }

        switch mode {
        case .handsFree:
            // 常にトグル。離しても止めない。
            startedByCurrentPress = false
        case .pushToTalk:
            startedByCurrentPress = false
            DispatchQueue.main.async { [weak self] in self?.onStop?() }
        case .auto:
            if isHold {
                startedByCurrentPress = false
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
            } else {
                // 短押し = トグル。次に押されるまで録り続ける。
                startedByCurrentPress = false
            }
        }
        isHold = false
    }
}

/// キーコードを人が読める名前にする（設定画面の表示用）。
enum KeyCodeNames {
    private static let table: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func name(for code: Int, modifiers: UInt64) -> String {
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(table[code] ?? "キーコード \(code)")
        return parts.joined()
    }
}
