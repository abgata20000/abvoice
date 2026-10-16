import Foundation
import WhisperKit

/// 文字起こしモデルの状態。
enum WhisperModelStatus: Equatable {
    /// まだ取得していない。
    case notDownloaded
    /// 取得中。0〜1。
    case downloading(Double)
    /// メモリに載せている最中。⚠️ 取得した直後の 1 回目は分単位でかかる。
    case preparing
    case ready
    case failed(String)
}

/// 文字起こしモデルの有無確認・取得・読み込み・削除。
///
/// ⚠️ モデルはアプリに同梱しない（同梱すると配布物が 600MB を超える）。
///    初回に取得して `Application Support` の `Models/` に置く。
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published private(set) var status: WhisperModelStatus = .notDownloaded
    /// いま `status` が指しているモデル。
    @Published private(set) var variant: String = ""

    private init() {}

    /// 録音できないとき・画面に出すときの一言。
    var statusText: String {
        switch status {
        case .notDownloaded: return "文字起こしモデルがまだありません。設定から取得してください"
        case .downloading(let fraction): return "モデルを取得中です（\(Int(fraction * 100))%）"
        case .preparing: return "モデルを準備中です（取得した直後は数分かかります）"
        case .ready: return "使えます"
        case .failed(let reason): return "モデルを使えません: \(reason)"
        }
    }

    // MARK: 場所

    /// WhisperKit が取得したモデルを置く場所。`downloadBase` に `AppPaths.models` を渡したときの配置。
    func modelFolder(for variant: String) -> URL {
        AppPaths.models
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    /// 取得が最後まで終わった印。
    /// ⚠️ フォルダの有無では判定しない。取得はファイル単位で進むので、途中で止まるとフォルダは
    ///    あるのに中身が足りない状態になる。
    private func completionMarker(for variant: String) -> URL {
        modelFolder(for: variant).appendingPathComponent(".download-complete")
    }

    func isDownloaded(_ variant: String) -> Bool {
        FileManager.default.fileExists(atPath: completionMarker(for: variant).path)
    }

    // MARK: 読み込み

    /// 取得済みならメモリに載せる。まだなら「取得していない」にするだけ（勝手に取得は始めない）。
    /// 起動時と、設定でモデルを切り替えたときに呼ぶ。
    func prepare(variant: String) async {
        self.variant = variant
        guard isDownloaded(variant) else {
            await WhisperEngine.shared.unload()
            status = .notDownloaded
            return
        }
        await load(variant: variant)
    }

    private func load(variant: String) async {
        status = .preparing
        let started = Date()
        do {
            try await WhisperEngine.shared.load(
                variant: variant, modelFolder: modelFolder(for: variant), downloadBase: AppPaths.models
            )
            // 待っている間に別のモデルへ切り替えられていたら、状態を上書きしない。
            guard self.variant == variant else { return }
            status = .ready
            Notifier.shared.info(String(
                format: "文字起こしモデルを読み込みました（%@ / %.1f 秒）", variant, Date().timeIntervalSince(started)
            ))
        } catch {
            guard self.variant == variant else { return }
            status = .failed(error.localizedDescription)
            Notifier.shared.error("文字起こしモデルを読み込めませんでした: \(error.localizedDescription)", notify: false)
        }
    }

    // MARK: 取得

    /// モデルを取得して、そのままメモリに載せる。
    /// ⚠️ 途中で切れても、もう一度呼べば続きから取る（WhisperKit が未完了のファイルを残している）。
    func downloadAndPrepare(variant: String) async {
        if case .downloading = status { return }
        self.variant = variant
        status = .downloading(0)
        Notifier.shared.info("文字起こしモデルの取得を始めます（\(variant)）")
        do {
            let folder = try await WhisperKit.download(variant: variant, downloadBase: AppPaths.models) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard ModelManager.shared.variant == variant,
                          case .downloading = ModelManager.shared.status else { return }
                    ModelManager.shared.status = .downloading(fraction)
                }
            }
            guard folder.standardizedFileURL == modelFolder(for: variant).standardizedFileURL else {
                // ⚠️ WhisperKit の置き場所が変わった。黙って進めると「取得済みなのに無い」になる。
                throw HTTPError.decoding("モデルが想定と違う場所に置かれました: \(folder.lastPathComponent)")
            }
            try Data().write(to: completionMarker(for: variant))
        } catch {
            guard self.variant == variant else { return }
            status = .failed("取得に失敗しました。もう一度押すと続きから取得します: \(error.localizedDescription)")
            Notifier.shared.error("文字起こしモデルの取得に失敗しました: \(error.localizedDescription)", notify: false)
            return
        }
        guard self.variant == variant else { return }
        await load(variant: variant)
    }

    // MARK: 削除

    func delete(variant: String) async {
        if self.variant == variant {
            await WhisperEngine.shared.unload()
            status = .notDownloaded
        }
        try? FileManager.default.removeItem(at: modelFolder(for: variant))
    }
}
