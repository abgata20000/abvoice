import AppKit
import Foundation

/// アプリの別名 1 件（「スラック」→ Slack）。
struct AppAlias: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String
    var aliases: [String]

    var id: String { bundleID }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case aliases
    }
}

/// アプリの別名表。`~/Library/Application Support/AbVoice/app-aliases.json` に持つ。
///
/// ⚠️ この Mac のファイルにだけ置く。Mac ごとに入っているアプリが違うため。
/// ⚠️ ファイルは自動生成しない。画面で 1 件足したときに初めて書き出す。
@MainActor
final class AppAliasStore: ObservableObject {
    static let shared = AppAliasStore()

    @Published private(set) var entries: [AppAlias] = []

    private init() {
        guard let data = try? Data(contentsOf: AppPaths.appAliases),
              let decoded = try? JSONDecoder().decode([AppAlias].self, from: data)
        else { return }
        entries = decoded
    }

    // MARK: 編集

    func add(bundleID: String, name: String) {
        guard !entries.contains(where: { $0.bundleID == bundleID }) else { return }
        entries.append(AppAlias(bundleID: bundleID, name: name, aliases: []))
        save()
    }

    func setAliases(_ aliases: [String], for bundleID: String) {
        guard let index = entries.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        entries[index].aliases = aliases
        save()
    }

    func remove(bundleID: String) {
        entries.removeAll { $0.bundleID == bundleID }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try data.write(to: AppPaths.appAliases, options: .atomic)
        } catch {
            Notifier.shared.warn("アプリの別名を保存できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: 照合の候補

    /// 起動中の通常アプリ（Dock に出るもの）。別名の追加候補にも使う。
    var runningApps: [AppTarget] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return AppTarget(bundleID: bundleID, name: name)
            }
    }

    /// パターン照合に渡す候補。別名表 → 組み込みの一般名 → 起動中アプリの表示名。
    func candidates() -> [CommandParser.Candidate] {
        var result: [CommandParser.Candidate] = []
        for entry in entries {
            let target = AppTarget(bundleID: entry.bundleID, name: entry.name)
            result.append(.init(phrase: entry.name, target: target))
            result += entry.aliases.map { .init(phrase: $0, target: target) }
        }
        result += builtIns()
        let running = runningApps
        result += running.map { .init(phrase: $0.name, target: $0) }
        result += Self.wordPhrases(for: running)
        return result
    }

    /// 複数語の名前を単語でも呼べるようにする（「Google Chrome」→「Chrome」）。
    /// ⚠️ 3 文字未満の語と、2 つ以上のアプリに出てくる語（「Microsoft」など）は使わない。
    static func wordPhrases(for apps: [AppTarget]) -> [CommandParser.Candidate] {
        var owners: [String: [AppTarget]] = [:]
        for app in apps {
            let words = app.name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            guard words.count > 1 else { continue }
            for word in Set(words.map { $0.lowercased() }) where word.count >= 3 {
                owners[word, default: []].append(app)
            }
        }
        return owners.compactMap { word, apps in
            apps.count == 1 ? CommandParser.Candidate(phrase: word, target: apps[0]) : nil
        }
    }

    /// LLM に渡す「選んでよいアプリ」の一覧。
    func targets() -> [AppTarget] {
        var seen = Set<String>()
        return candidates().map(\.target).filter { seen.insert($0.bundleID).inserted }
    }

    /// コマンド録音のときだけ whisper のプロンプトに足す語。聞き落としを減らすため。
    var promptTerms: String {
        entries.flatMap { [$0.name] + $0.aliases }.joined(separator: "、")
    }

    /// どの Mac でも通じる呼び方。
    private func builtIns() -> [CommandParser.Candidate] {
        var result: [CommandParser.Candidate] = []
        if let url = URL(string: "https://example.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            let name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            let browser = AppTarget(bundleID: bundleID, name: name)
            result.append(.init(phrase: "ブラウザ", target: browser))
        }
        let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")
        result.append(.init(phrase: "ファインダー", target: finder))
        result.append(.init(phrase: "Finder", target: finder))
        let settings = AppTarget(bundleID: "com.apple.systempreferences", name: "システム設定")
        result.append(.init(phrase: "システム設定", target: settings))
        return result
    }
}
