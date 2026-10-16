import XCTest
@testable import AbVoiceLocal

@MainActor
final class LocalHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("history.jsonl") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abvoice-local-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ text: String, daysAgo: Double = 0, app: String? = "Slack", now: Date = Date()) -> HistoryRecord {
        HistoryRecord(
            id: UUID().uuidString,
            createdAt: now.addingTimeInterval(-daysAgo * 86_400),
            rawText: text,
            text: text,
            engine: "local",
            formatModel: "none",
            durationMs: 4200,
            latencyMs: 1380,
            appName: app,
            appBundleID: nil
        )
    }

    private func lines() throws -> [String] {
        try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func test追記すると1行1件で保存され新しい順に並ぶ() throws {
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("一件目", daysAgo: 1))
        store.append(record("二件目"))

        XCTAssertEqual(store.records.map(\.text), ["二件目", "一件目"])
        XCTAssertEqual(try lines().count, 2)

        let reloaded = LocalHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.records.map(\.text), ["二件目", "一件目"])
    }

    /// ⚠️ 改行を含むテキストでも 1 行 1 件が崩れない。
    func test改行を含むテキストでも1行に収まる() throws {
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("一行目\n二行目"))

        XCTAssertEqual(try lines().count, 1)
        XCTAssertEqual(LocalHistoryStore(fileURL: fileURL).records.first?.text, "一行目\n二行目")
    }

    func test検索は本文とアプリ名に当たる() {
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("見積もりを送りました", app: "Mail"))
        store.append(record("会議は十時からです", app: "Slack"))

        XCTAssertEqual(store.search("見積もり").map(\.text), ["見積もりを送りました"])
        XCTAssertEqual(store.search("slack").map(\.text), ["会議は十時からです"])
        XCTAssertEqual(store.search("  ").count, 2)
        XCTAssertTrue(store.search("該当なし").isEmpty)
    }

    func test保持期間を過ぎた行だけ落とす() throws {
        let now = Date()
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("古い", daysAgo: 100, now: now))
        store.append(record("新しい", daysAgo: 10, now: now))

        store.prune(retentionDays: 90, now: now)

        XCTAssertEqual(store.records.map(\.text), ["新しい"])
        XCTAssertEqual(try lines().count, 1)
    }

    func test保持期間が0なら無期限で何も落とさない() {
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("古い", daysAgo: 1000))

        store.prune(retentionDays: 0)

        XCTAssertEqual(store.records.count, 1)
    }

    func test1件削除と全削除がファイルにも反映される() throws {
        let store = LocalHistoryStore(fileURL: fileURL)
        let first = record("一件目", daysAgo: 1)
        store.append(first)
        store.append(record("二件目"))

        store.delete(id: first.id)
        XCTAssertEqual(LocalHistoryStore(fileURL: fileURL).records.map(\.text), ["二件目"])

        store.deleteAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(LocalHistoryStore(fileURL: fileURL).records.isEmpty)
    }

    /// 追記の途中で落ちた最終行などがあっても、読める行は読む。
    func test壊れた行があっても残りは読める() throws {
        let store = LocalHistoryStore(fileURL: fileURL)
        store.append(record("読める"))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\": \"壊れた行".utf8))
        try handle.close()

        XCTAssertEqual(LocalHistoryStore(fileURL: fileURL).records.map(\.text), ["読める"])
    }
}
