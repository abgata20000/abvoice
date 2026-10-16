import SwiftUI

/// 音声コマンド（喋ってウィンドウを操作する）の設定画面。
struct CommandsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = VoiceCoordinator.shared
    @ObservedObject private var aliases = AppAliasStore.shared

    @State private var capturingHotkey = false
    @State private var hotkeyMessage: String?
    @State private var trialText = ""

    /// 覚えなくても見れば分かるように、言い方をそのまま出す。
    private static let examples: [(action: String, phrase: String)] = [
        ("前面に出す", "「Chrome を前に出して」「ブラウザを開いて」「Slack」"),
        ("最大化", "「最大化して」「いっぱいに広げて」"),
        ("左右の半分", "「右半分にして」「左に寄せて」"),
        ("上下の半分", "「上半分にして」「下半分にして」"),
        ("四隅の 1/4", "「右上にして」「左下 4 分の 1 にして」"),
        ("中央に置く", "「真ん中に置いて」"),
        ("元に戻す", "「元のサイズに戻して」"),
        ("最小化", "「最小化して」「しまって」"),
        ("隠す", "「Slack を隠して」"),
        ("別のディスプレイへ", "「右のモニターに移して」「隣の画面に移して」"),
        ("ディスプレイを選んで配置", "「左のモニターで最大化して」「真ん中の画面の右半分にして」"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enableSection
                Divider()
                hotkeySection
                Divider()
                aliasSection
                Divider()
                exampleSection
                Divider()
                trialSection
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    // MARK: オン / オフ

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音声コマンド").font(.headline)
            Toggle("喋ってウィンドウを操作する", isOn: Binding(
                get: { settings.commandsEnabled },
                set: { settings.commandsEnabled = $0; coordinator.applyHotkeySettings() }
            ))
            Toggle("決まった言い方で解釈できないときは LLM に聞く", isOn: $settings.commandLLMFallbackEnabled)
                .disabled(!settings.commandsEnabled)
            Text("コマンドは何も挿入しません。履歴にも残りません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: コマンドキー

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("コマンドキー").font(.headline)
            HStack(spacing: 12) {
                Text(KeyCodeNames.name(for: settings.commandHotKeyCode, modifiers: settings.commandHotKeyModifiers))
                    .font(.title3.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Button(capturingHotkey ? "キーを押してください…" : "キーを記録") {
                    if capturingHotkey {
                        coordinator.cancelHotkeyCapture()
                        capturingHotkey = false
                    } else {
                        capturingHotkey = true
                        hotkeyMessage = nil
                        coordinator.beginHotkeyCapture { code, modifiers in
                            capturingHotkey = false
                            // ⚠️ 口述キーと同じ組み合わせは登録させない（どちらの録音か決められなくなる）。
                            if code == settings.hotKeyCode, modifiers == settings.hotKeyModifiers {
                                hotkeyMessage = "口述のホットキーと同じ組み合わせは使えません。"
                                return
                            }
                            settings.commandHotKeyCode = code
                            settings.commandHotKeyModifiers = modifiers
                            coordinator.applyHotkeySettings()
                        }
                    }
                }
                .disabled(!coordinator.hotkeyActive)

                Button("⌃⌥⌘Space に戻す") {
                    settings.commandHotKeyCode = 49
                    settings.commandHotKeyModifiers = CGEventFlags.maskControl.rawValue
                        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
                    coordinator.applyHotkeySettings()
                    hotkeyMessage = nil
                }
                .controlSize(.small)
            }
            if let hotkeyMessage {
                Text(hotkeyMessage).font(.caption).foregroundStyle(.orange)
            }
            Text("押している間だけ聞き、離したら実行します（録音モードの設定に関係なく、常に押しっぱなし）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!settings.commandsEnabled)
    }

    // MARK: アプリの別名

    private var aliasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("アプリの別名").font(.headline)
                Spacer()
                Menu("アプリを追加") {
                    let registered = Set(aliases.entries.map(\.bundleID))
                    let addable = aliases.runningApps
                        .filter { !registered.contains($0.bundleID) }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    if addable.isEmpty {
                        Text("追加できるアプリがありません（起動中のアプリから選びます）")
                    }
                    ForEach(addable, id: \.bundleID) { app in
                        Button(app.name) { aliases.add(bundleID: app.bundleID, name: app.name) }
                    }
                }
                .fixedSize()
            }
            Text("起動中のアプリは表示名（Slack など）でそのまま呼べます。カタカナや呼び名で呼びたいときに足してください。「ブラウザ」は既定のブラウザを指します。")
                .font(.caption).foregroundStyle(.secondary)

            if aliases.entries.isEmpty {
                Text("まだ登録がありません。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(aliases.entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.name).frame(width: 150, alignment: .leading).lineLimit(1)
                    TextField("別名（読点かカンマで区切る）", text: Binding(
                        get: { entry.aliases.joined(separator: "、") },
                        set: { aliases.setAliases(Self.split($0), for: entry.bundleID) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        aliases.remove(bundleID: entry.bundleID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("この別名を削除")
                }
            }
        }
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: 使える言い方

    private var exampleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使える言い方").font(.headline)
            ForEach(Self.examples, id: \.action) { example in
                HStack(alignment: .top, spacing: 8) {
                    Text(example.action).frame(width: 130, alignment: .leading)
                    Text(example.phrase).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("アプリ名を付けると（「Slack を右半分に」）そのアプリを前に出してから動かします。付けなければ、いま前面にあるウィンドウが対象です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 試す

    /// 喋らずにキーワードの当たり外れを確かめる。⚠️ 表示するだけで実行はしない。LLM にも聞かない。
    private var trialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("試す").font(.headline)
            TextField("例: スラックを右半分にして", text: $trialText)
                .textFieldStyle(.roundedBorder)
            if !trialText.trimmingCharacters(in: .whitespaces).isEmpty {
                let commands = CommandParser.parse(trialText, candidates: aliases.candidates())
                if commands.isEmpty {
                    Label("決まった言い方では解釈できません（LLM に回ります）", systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                        Label("\(command.target?.name ?? "前面のウィンドウ") を\(command.phrase)",
                              systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.green)
                    }
                }
            }
            Text("ここでは解釈の結果を見るだけで、ウィンドウは動きません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
