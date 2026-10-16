import AppKit
import SwiftUI

/// 録音中から挿入までの状態。
///
/// ⚠️ 録音を止めてから挿入までは数秒かかることがある（OpenAI に落ちると特に長い）。
///    そこが無表示だと「無反応」にしか見えないので、どの段階にいるかを必ず出す。
enum PipelineStage: Equatable {
    case idle
    case recording
    case transcribing
    case formatting(model: String)
    case inserting
    case done(text: String, engine: String, latencyMs: Int)
    case failed(String)
    /// 挿入しなかっただけで、失敗ではない状態（無音・ハルシネーション）。
    /// ⚠️ `failed` と分けているのは、喋っていないだけなのにオレンジの警告が出ると大げさなため。
    case skipped(String)

    var isVisible: Bool { self != .idle }
}

/// 録音中と処理中を画面上に常時出すフローティング表示。
///
/// ⚠️ `.nonactivatingPanel` にして自分をフォアグラウンドにしない。
///    挿入先は「停止時点でフォーカスされているアプリ」なので、ここで前面を奪ってはいけない。
@MainActor
final class RecordingIndicator {
    static let shared = RecordingIndicator()

    /// 録音中のサイズ。喋っている間ずっと視界にいるので小さくする。
    static let compactSize = NSSize(width: 200, height: 52)
    /// 速報が出ているときの録音中サイズ。⚠️ 広げるのは録音中だけ。
    ///
    /// 12pt で 5 行ぶん ≒ 約 170 字 ＝ 口述 30 秒ぶんが見える大きさ
    /// （S/M/L の実寸モックを見比べて M を選んだ）。
    /// ⚠️ ここを変えたら実機で「邪魔になっていないか」を必ず見ること。録音中はずっと視界にいる。
    static let previewSize = NSSize(width: 440, height: 138)
    /// 速報つき表示の内訳（pt）。⚠️ 本文の高さを固定値で切る必要があるので、
    ///    ヘッダとメーターの高さもここで決めて辻褄を合わせる。
    static let previewFontSize: CGFloat = 12
    static let previewHeaderHeight: CGFloat = 15
    static let previewMeterHeight: CGFloat = 5
    static let previewPadding: CGFloat = 10
    static let previewSpacing: CGFloat = 6
    /// 速報の本文に残る高さ。12pt なら 5 行ぶんくらい。
    static var previewBodyHeight: CGFloat {
        previewSize.height
            - previewPadding * 2
            - previewHeaderHeight
            - previewSpacing * 2
            - previewMeterHeight
    }

    /// 挿入結果やエラーを読ませる段階のサイズ。
    static let fullSize = NSSize(width: 320, height: 84)
    /// 設定へ飛べるときのサイズ。⚠️「クリックで開く」の一言ぶん高くする。
    static let actionableSize = NSSize(width: 340, height: 106)
    /// 画面端からの余白。
    private static let margin: CGFloat = 24

    private var panel: NSPanel?
    /// いま速報が出ているか。録音中のサイズを決めるのに使う。
    private var hasPreview = false
    /// いま飛び先があるか。サイズを決めるのに使う。
    private var hasDestination = false

    private init() {}

    func show(for stage: PipelineStage, destination: AppDestination? = nil) {
        if case .recording = stage {} else { hasPreview = false }
        hasDestination = destination != nil
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.setContentSize(size(for: stage))
        // ⚠️⚠️ 飛び先があるときだけマウスを受け取る。
        //    録音中・処理中に受け取ると、下のアプリを操作できなくなる（挿入先を邪魔する）。
        //    この状態は 2〜6 秒で自動的に消えるので、塞ぐ時間は短い。
        panel.ignoresMouseEvents = (destination == nil)
        reposition(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        hasPreview = false
        hasDestination = false
        // ⚠️ 戻し忘れるとマウスを食い続ける。消すときは必ず true に戻す。
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    /// 速報の有無が変わったら録音中の表示を広げ／縮める。
    /// ⚠️ 位置の設定（右下など）はそのまま効かせるので、必ず reposition も通す。
    func updatePreview(hasPreview: Bool) {
        guard self.hasPreview != hasPreview else { return }
        self.hasPreview = hasPreview
        guard let panel, panel.isVisible,
              case .recording = VoiceCoordinator.shared.stage else { return }
        panel.setContentSize(hasPreview ? Self.previewSize : Self.compactSize)
        // ⚠️ 録音中は絶対にマウスを取らない（喋っている最中に下のアプリを塞がない）。
        panel.ignoresMouseEvents = true
        reposition(panel)
    }

    private func size(for stage: PipelineStage) -> NSSize {
        if case .recording = stage { return hasPreview ? Self.previewSize : Self.compactSize }
        return hasDestination ? Self.actionableSize : Self.fullSize
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.fullSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView())
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let margin = Self.margin

        // ⚠️ 置く前に画面に収まる大きさへ落とす。速報つきは 440 幅あるので、
        //    小さい画面や外部ディスプレイを外した直後に画面外へ出さないための保険。
        var size = panel.frame.size
        size.width = min(size.width, max(0, frame.width - margin * 2))
        size.height = min(size.height, max(0, frame.height - margin * 2))
        if size != panel.frame.size { panel.setContentSize(size) }

        let x: CGFloat
        let y: CGFloat
        switch AppSettings.shared.indicatorPosition {
        case .bottomRight:
            x = frame.maxX - size.width - margin
            y = frame.minY + margin
        case .bottomLeft:
            x = frame.minX + margin
            y = frame.minY + margin
        case .bottomCenter:
            x = frame.midX - size.width / 2
            y = frame.minY + margin
        case .topRight:
            x = frame.maxX - size.width - margin
            y = frame.maxY - size.height - margin
        case .topLeft:
            x = frame.minX + margin
            y = frame.maxY - size.height - margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct RecordingIndicatorView: View {
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var realtime = VoiceCoordinator.shared.realtime

    /// 速報として組ませる末尾の文字数。
    /// ⚠️ 「画面に出す量」ではない。表示は下から積み上げてあふれたぶんを切るので、
    ///    ここは長い口述で無限にレイアウトさせないための上限でしかない。
    private static let previewKeepLength = 600

    /// 飛び先の有無でパネルのサイズが変わるので、中身もそれに合わせる。
    private var fullBoxSize: NSSize {
        coordinator.stageDestination == nil ? RecordingIndicator.fullSize : RecordingIndicator.actionableSize
    }

    var body: some View {
        Group {
            if case .recording = coordinator.stage {
                // ⚠️ 録音中は喋っている間ずっと視界にいる。出す情報を絞って小さくする。
                //    速報が出たときだけ広げる。
                if realtime.text.isEmpty { compact } else { recordingWithPreview }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    detail
                    // ⚠️ 出さないと押せることに気づけない。
                    if let destination = coordinator.stageDestination {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                            Text(destination.hint)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tint)
                    }
                }
                .padding(12)
                .frame(width: fullBoxSize.width, height: fullBoxSize.height, alignment: .topLeading)
                // ⚠️ パネル側で飛び先があるときだけマウスを受け取っている。
                //    録音中・処理中はここに来てもクリックは届かない。
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let destination = coordinator.stageDestination else { return }
                    AppNavigator.shared.go(to: destination)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // ⚠️ コマンドは喋っても文字が入らない。口述と取り違えないよう、録音中から結果が消えるまで枠で示す。
        .overlay {
            if isCommand {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Self.commandColor, lineWidth: 2)
            }
        }
    }

    private static let commandColor = Color.purple

    private var isCommand: Bool { coordinator.recordingPurpose == .command }

    /// 録音中の見出し。口述は赤丸 +「録音中」、コマンドは紫のウィンドウ印 +「コマンド」。
    @ViewBuilder
    private var recordingBadge: some View {
        if isCommand {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Self.commandColor)
            Text("コマンド").font(.system(size: 11, weight: .semibold))
        } else {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("録音中").font(.system(size: 11, weight: .semibold))
        }
    }

    /// 録音中の最小表示。赤丸・経過時間・レベルメーターだけ。
    private var compact: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                recordingBadge
                Spacer()
                Text(elapsedLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LevelMeter(level: coordinator.level).frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(
            width: RecordingIndicator.compactSize.width,
            height: RecordingIndicator.compactSize.height,
            alignment: .topLeading
        )
    }

    /// 速報つきの録音中表示。
    ///
    /// ⚠️ ここに出ているのはオンデバイスの**速報**。挿入されるのは停止後の確定テキストで、
    ///    固有名詞の取りこぼし（「ラウンドメイト」→「サウンドメイト」）は確定側で直る。
    private var recordingWithPreview: some View {
        // ⚠️ spacing / padding は RecordingIndicator の定数を使う。
        //    直値に戻すと previewBodyHeight の計算と食い違う。
        VStack(alignment: .leading, spacing: RecordingIndicator.previewSpacing) {
            HStack(spacing: 8) {
                recordingBadge
                Spacer()
                Text(elapsedLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // ⚠️ 高さを固定する。本文に残る高さを数えられないと previewBodyHeight が合わなくなる。
            .frame(height: RecordingIndicator.previewHeaderHeight)
            LevelMeter(level: coordinator.level).frame(height: RecordingIndicator.previewMeterHeight)
            previewBody
        }
        .padding(.horizontal, 12)
        .padding(.vertical, RecordingIndicator.previewPadding)
        .frame(
            width: RecordingIndicator.previewSize.width,
            height: RecordingIndicator.previewSize.height,
            alignment: .topLeading
        )
    }

    /// 速報の本文。
    ///
    /// ⚠️⚠️ **末尾（いま喋っているところ）を必ずいちばん下の行に置く。** あふれたぶんだけを上へ
    ///    押し出して切る。「末尾 N 文字を切り出して `truncationMode(.head)` で頭を落とす」やり方に
    ///    戻さないこと。1 文字増えるたびに全行が組み直されて、読んでいる場所が毎秒ずれる。
    private var previewBody: some View {
        previewText
            .font(.system(size: RecordingIndicator.previewFontSize))
            // ⚠️ これが無いと Text 側で truncate されてしまい、上へあふれてくれない。
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️⚠️ **高さは固定値で切る。** `maxHeight: .infinity` にすると枠が本文の高さまで
            //    伸びてしまい（可変フレームは子より小さくならない）、上ではなく下へあふれる。
            //    実際にそうなったのを確認済み。
            .frame(height: RecordingIndicator.previewBodyHeight, alignment: .bottom)
            .clipped()
            // 押し出されたぶんは上端で薄くなって消える。
            // ⚠️ 本文が短いうちは上側が空くので、フェードは出しっぱなしでよい。
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    /// 確定済みは薄く、いま喋っている未確定部分は濃く。
    ///
    /// ⚠️ 1 つの `AttributedString` にまとめる。`VStack` で 2 つの `Text` に分けると
    ///    1 つの段落として折り返されず、確定と未確定の境目で必ず改行が入ってしまう。
    ///    （`Text` + `Text` の連結でも同じことができるが `+` は macOS 26 で非推奨。）
    private var previewText: Text {
        let runs = previewRuns
        var attributed = AttributedString(runs.confirmed)
        attributed.foregroundColor = Color.secondary
        var tail = AttributedString(runs.volatile)
        tail.foregroundColor = Color.primary
        attributed.append(tail)
        return Text(attributed)
    }

    /// 表示に回す確定ぶん・未確定ぶん。⚠️ 長い口述で青天井にならないよう末尾だけに絞る。
    private var previewRuns: (confirmed: String, volatile: String) {
        let volatile = realtime.volatileText
        let keep = Self.previewKeepLength
        guard volatile.count < keep else {
            return ("", breakBySentence(String(volatile.suffix(keep)), isTail: true))
        }
        let confirmed = String(realtime.confirmedText.suffix(keep - volatile.count))
        return (
            breakBySentence(confirmed, isTail: volatile.isEmpty),
            breakBySentence(volatile, isTail: true)
        )
    }

    /// 句点のうしろで改行して、文単位に積む。確定した行はもう動かないので増えたぶんが目に入る。
    ///
    /// ⚠️ **表示だけの加工。** 挿入されるテキスト（確定側）には一切影響しない。
    /// ⚠️ 速報に句読点が出ない場合は何も置き換わらないだけ（そのときは詰めて流れる）。
    private func breakBySentence(_ text: String, isTail: Bool) -> String {
        var broken = ""
        for character in text {
            broken.append(character)
            if character == "。" || character == "？" || character == "！" {
                broken.append("\n")
            }
        }
        // ⚠️ 末尾の改行を残すと空行ぶん本文が持ち上がり、最終行が定位置に来ない。
        if isTail, broken.hasSuffix("\n") { broken.removeLast() }
        return broken
    }

    private var elapsedLabel: String {
        let total = Int(coordinator.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            icon
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch coordinator.stage {
        case .recording:
            Circle().fill(Color.red).frame(width: 10, height: 10)
        case .transcribing, .formatting, .inserting:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
        case .skipped:
            Image(systemName: "mic.slash").foregroundStyle(.secondary).font(.system(size: 12))
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch coordinator.stage {
        case .idle: return ""
        case .recording: return "録音中"
        case .transcribing: return "文字起こし中…"
        // ⚠️ コマンドは何も挿入しない。口述の文言のままだと「挿入しました」と出て嘘になる。
        case .formatting(let model): return isCommand ? "解釈中…（\(model)）" : "整形中…（\(model)）"
        case .inserting: return "挿入中…"
        case .done: return isCommand ? "実行しました" : "挿入しました"
        case .failed: return "失敗しました"
        case .skipped: return "声が入っていません"
        }
    }

    private var trailing: String? {
        switch coordinator.stage {
        case .recording:
            let total = Int(coordinator.elapsed)
            return String(format: "%02d:%02d", total / 60, total % 60)
        case .transcribing, .formatting, .inserting:
            return String(format: "%.1fs", coordinator.processingElapsed)
        case .done(_, let engine, let latencyMs):
            // ⚠️ OpenAI を使ったときは音声が送られ、課金されている。ここで気づけるようにする。
            let label = engine == "openai" ? "OpenAI 課金" : "この Mac"
            return String(format: "%@ · %.2fs", label, Double(latencyMs) / 1000)
        default:
            return nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch coordinator.stage {
        case .recording:
            LevelMeter(level: coordinator.level).frame(height: 6)
            Text("もう一度ホットキーで停止 / Escape で破棄")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .transcribing, .formatting, .inserting:
            Text(coordinator.processingCount > 1
                 ? "\(coordinator.processingCount) 件を処理中。この間も次の録音を始められます。"
                 : "この間も次の録音を始められます。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .done(let text, _, _):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .skipped(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }
}

/// 音量レベルのバー。マイクが拾えているかを目で確認できるようにする。
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * CGFloat(normalized))
            }
        }
    }

    /// RMS はそのままだと動きが小さいので対数寄りに伸ばす。
    private var normalized: Float {
        let clamped = max(0.0005, min(1, level))
        let db = 20 * log10(clamped)          // -66dB 〜 0dB あたり
        return max(0, min(1, (db + 60) / 60))
    }
}
