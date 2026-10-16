import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 辞書の編集画面。この Mac の辞書ファイルを直接触る。
///
/// ⚠️ 辞書の正本は `LocalDictionaryStore` が持つ。この画面は別のコピーを持たない
///    （辞書に誤変換を足したら、次の発話から効くこと）。
struct DictionaryView: View {
    @ObservedObject private var store = LocalDictionaryStore.shared
    @State private var editing: DictionaryEntry?
    @State private var showingNew = false
    /// 書き出し・読み込みの結果（成功も失敗もここに出す）。
    @State private var transferMessage: String?
    @State private var transferFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(store.entries.count) 語").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    importDictionary()
                } label: {
                    Label("読み込み", systemImage: "square.and.arrow.down")
                }
                .help("JSON の辞書を取り込む。同じ表記の語は、読み込んだ側で上書きする")
                Button {
                    exportDictionary()
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .help("辞書を JSON で保存する")
                .disabled(store.entries.isEmpty)
                Button {
                    showingNew = true
                } label: {
                    Label("追加", systemImage: "plus")
                }
            }
            .controlSize(.small)
            .padding(12)
            // ⚠️ ファイルを読めなかったときは編集させない。保存されないのに成功したように見えるため。
            .disabled(store.isReadOnly)

            if let message = store.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .foregroundStyle(.orange)
            }

            if let message = transferMessage {
                Label(message, systemImage: transferFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .foregroundStyle(transferFailed ? .orange : .secondary)
            }

            if store.entries.isEmpty {
                emptyGuide.disabled(store.isReadOnly)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(entry.term).font(.body.bold())
                                    if let reading = entry.reading, !reading.isEmpty {
                                        Text("（\(reading)）").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if entry.wrongForms.isEmpty {
                                    Text("誤変換の登録なし").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    Text("→ " + entry.wrongForms.joined(separator: " / "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("編集") { editing = entry }.controlSize(.small)
                            Button("削除") { store.delete(id: entry.id) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            DictionaryEntryEditor(entry: nil) { term, reading, wrongForms in
                store.add(term: term, reading: reading, wrongForms: wrongForms)
            }
        }
        .sheet(item: $editing) { entry in
            DictionaryEntryEditor(entry: entry) { term, reading, wrongForms in
                var updated = entry
                updated.term = term
                updated.reading = reading
                updated.wrongForms = wrongForms
                store.update(updated)
            }
        }
    }

    /// 辞書が空のときの案内。最初の一歩を具体的に示す。
    private var emptyGuide: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed").font(.largeTitle).foregroundStyle(.secondary)
            Text("まず自分の名前と、よく使う製品名を 5 個入れてみてください")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingNew = true
            } label: {
                Label("追加", systemImage: "plus")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 書き出し・読み込み

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
            transferMessage = "\(store.entries.count) 語を書き出しました"
            transferFailed = false
        } catch {
            transferMessage = "書き出せませんでした: \(error.localizedDescription)"
            transferFailed = true
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importData(Data(contentsOf: url))
            transferMessage = "\(count) 語を読み込みました"
            transferFailed = false
        } catch {
            transferMessage = "読み込めませんでした: \(error.localizedDescription)"
            transferFailed = true
        }
    }
}

private struct DictionaryEntryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (String, String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var reading: String
    @State private var wrongForms: String

    init(entry: DictionaryEntry?, onSave: @escaping (String, String, [String]) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _term = State(initialValue: entry?.term ?? "")
        _reading = State(initialValue: entry?.reading ?? "")
        _wrongForms = State(initialValue: (entry?.wrongForms ?? []).joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "辞書に追加" : "辞書を編集").font(.headline)

            Form {
                TextField("正しい表記（term）", text: $term)
                TextField("読み（reading）", text: $reading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("誤変換（wrong_forms）— 1 行に 1 つ").font(.callout)
                Text("ここに入れた語は、LLM 整形の後に機械置換で正しい表記へ戻ります。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $wrongForms)
                    .font(.body.monospaced())
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    let forms = wrongForms
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(term.trimmingCharacters(in: .whitespaces), reading, forms)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
