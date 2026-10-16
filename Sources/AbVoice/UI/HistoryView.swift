import SwiftUI

/// ウィンドウの主役。喋った内容が新しい順に並ぶ。
///
/// ⚠️ 履歴はこの Mac のファイルにだけある。音声は保存していないので、再生はできない。
struct HistoryView: View {
    @ObservedObject private var store = LocalHistoryStore.shared
    @State private var query = ""
    @State private var confirmingDeleteAll = false

    /// 検索欄が空なら全件。
    private var records: [HistoryRecord] { store.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let message = store.lastError {
                errorBanner(message)
            }

            content
        }
    }

    // MARK: 上部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("履歴を検索（日本語の部分一致）", text: $query)
                .textFieldStyle(.plain)
            Button(role: .destructive) {
                confirmingDeleteAll = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("履歴をすべて削除")
            .disabled(store.records.isEmpty)
            // ⚠️ 全削除は取り消せないので、必ず確認を挟む。
            .confirmationDialog(
                "履歴をすべて削除しますか？",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("\(store.records.count) 件をすべて削除", role: .destructive) {
                    store.deleteAll()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この Mac に保存している履歴がすべて消えます。取り消せません。")
            }
        }
        .padding(12)
    }

    /// ⚠️ 履歴を保存できなくても挿入は動く。そのことを画面で明示する。
    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("履歴を保存できませんでした", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.bold())
            Text("文字起こしと挿入は、この状態でも動きます。")
                .font(.caption)
            Text(message).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: 一覧

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                Text(store.records.isEmpty ? "まだ記録がありません" : "一致する記録がありません")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(records) { record in
                        HistoryRow(record: record)
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    @State private var showRaw = false
    @State private var copied = false

    /// 整形や辞書置換で変わったときだけ、文字起こしそのままを見られるようにする。
    private var hasDistinctRaw: Bool {
        !record.rawText.isEmpty && record.rawText != record.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displayText)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showRaw, hasDistinctRaw {
                Text(record.rawText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text(meta).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 6) {
                Button {
                    TextInserter.copyToPasteboard(record.displayText)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "コピーした" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Button {
                    VoiceCoordinator.shared.reinsert(record.displayText)
                } label: {
                    Label("再挿入", systemImage: "arrow.down.doc")
                }

                if hasDistinctRaw {
                    Button {
                        showRaw.toggle()
                    } label: {
                        Label(showRaw ? "生テキストを隠す" : "生テキスト", systemImage: "text.quote")
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    LocalHistoryStore.shared.delete(id: record.id)
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var meta: String {
        var parts: [String] = []
        parts.append(Formatters.time.string(from: record.createdAt))
        if let app = record.appName, !app.isEmpty { parts.append(app) }
        parts.append(String(format: "%.2fs", Double(record.latencyMs) / 1000))
        parts.append(record.engine == "openai" ? "OpenAI（課金）" : "ローカル")
        if record.formatModel != "none" { parts.append(record.formatModel) }
        return parts.joined(separator: " · ")
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}
