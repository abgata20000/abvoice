import AppKit
import Foundation
import UserNotifications

/// アプリ内のイベント記録。設定画面や接続状態から直近の出来事を追えるようにする。
struct LogEntry: Identifiable {
    enum Level: String {
        case info, warn, error
    }

    let id = UUID()
    let at: Date
    let level: Level
    let message: String
}

/// 通知（音 + 通知センター + アプリ内ログ）。
@MainActor
final class Notifier: ObservableObject {
    static let shared = Notifier()

    @Published private(set) var entries: [LogEntry] = []
    /// 直近のエラー。画面上部の帯に出す。
    @Published var lastError: String?

    private var notificationsAuthorized = false

    /// ⚠️ 画面のログはアプリを閉じると消える。原因を後から追えるようにファイルにも残す。
    private let fileQueue = DispatchQueue(label: "jp.abgata.abvoice.local.log")
    private let logURL = AppPaths.root.appendingPathComponent("abvoice-local.log")
    private let logSizeLimit = 1_000_000

    private init() {
        trimLogIfNeeded()
        append(.info, "起動しました")
    }

    /// 肥大化を防ぐ。古い分は捨てる（診断に使うのは直近だけ）。
    private func trimLogIfNeeded() {
        let path = logURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > logSizeLimit else { return }
        try? FileManager.default.removeItem(at: logURL)
    }

    private func writeToFile(_ level: LogEntry.Level, _ message: String) {
        let stamp = Self.stampFormatter.string(from: Date())
        let line = "[\(stamp)] \(level.rawValue.uppercased()) \(message.replacingOccurrences(of: "\n", with: " / "))\n"
        let url = logURL
        fileQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAuthorized = granted }
        }
    }

    func info(_ message: String) { append(.info, message) }

    func warn(_ message: String, notify: Bool = false) {
        append(.warn, message)
        if notify { post(title: "AbVoice Local", body: message) }
    }

    func error(_ message: String, notify: Bool = true) {
        append(.error, message)
        lastError = message
        if notify { post(title: "AbVoice Local", body: message) }
    }

    private func append(_ level: LogEntry.Level, _ message: String) {
        entries.insert(LogEntry(at: Date(), level: level, message: message), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        writeToFile(level, message)
    }

    /// ログファイルの場所（設定画面から開けるようにする）。
    var logFileURL: URL { logURL }

    private func post(title: String, body: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 音

    /// 録音を開始した。
    func playStartSound() { play("Tink") }

    /// コマンドの録音を開始した。⚠️ 口述と聞き分けられるよう音を変える。
    func playCommandStartSound() { play("Morse") }

    /// 録音が止まった。⚠️ 止まったことに気づかず喋り続ける事故を防ぐため、必ず鳴らす。
    func playStopSound() { play("Pop") }

    /// 録音を破棄した。
    func playCancelSound() { play("Funk") }

    /// 失敗した。
    func playErrorSound() { play("Basso") }

    private func play(_ name: String) {
        guard AppSettings.shared.soundFeedbackEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
