import XCTest
@testable import AbVoiceLocal

@MainActor
final class LocalDictionaryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("dictionary.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abvoice-local-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test誤変換を正しい表記に置き換える() {
        let store = LocalDictionaryStore(fileURL: fileURL)
        store.add(term: "Slack", reading: "スラック", wrongForms: ["スラック", "すらっく"])

        XCTAssertEqual(store.applyReplacements(to: "スラックに貼りました"), "Slackに貼りました")
        XCTAssertEqual(store.applyReplacements(to: "すらっくを開く"), "Slackを開く")
        XCTAssertEqual(store.applyReplacements(to: "関係ない文"), "関係ない文")
    }

    /// ⚠️ 短い誤変換を先に当てると、長い誤変換の一部を壊してしまう。
    func test長い誤変換から先に当てる() {
        let store = LocalDictionaryStore(fileURL: fileURL)
        store.add(term: "GitHub", reading: nil, wrongForms: ["ギット"])
        store.add(term: "GitHub Actions", reading: nil, wrongForms: ["ギットハブアクションズ"])

        XCTAssertEqual(store.applyReplacements(to: "ギットハブアクションズが落ちた"), "GitHub Actionsが落ちた")
    }

    func test正しい表記と同じ誤変換は無視する() {
        let store = LocalDictionaryStore(fileURL: fileURL)
        store.add(term: "Docker", reading: nil, wrongForms: ["Docker", "  ", "ドッカー"])

        XCTAssertEqual(store.entries.first?.wrongForms, ["Docker", "ドッカー"])
        XCTAssertEqual(store.applyReplacements(to: "Dockerとドッカー"), "DockerとDocker")
    }

    func test保存した辞書を別のインスタンスが読める() {
        let first = LocalDictionaryStore(fileURL: fileURL)
        first.add(term: "Slack", reading: "スラック", wrongForms: ["スラック"])

        let second = LocalDictionaryStore(fileURL: fileURL)
        XCTAssertEqual(second.entries.map(\.term), ["Slack"])
        XCTAssertEqual(second.applyReplacements(to: "スラック"), "Slack")
    }

    func test書き出して読み込むと元に戻る() throws {
        let source = LocalDictionaryStore(fileURL: fileURL)
        source.add(term: "Slack", reading: "スラック", wrongForms: ["スラック"])
        source.add(term: "Docker", reading: nil, wrongForms: ["ドッカー", "どっかー"])
        let exported = try source.exportData()

        let target = LocalDictionaryStore(fileURL: directory.appendingPathComponent("other.json"))
        XCTAssertEqual(try target.importData(exported), 2)

        XCTAssertEqual(target.entries.map(\.term), source.entries.map(\.term))
        XCTAssertEqual(target.entries.map(\.wrongForms), source.entries.map(\.wrongForms))
        XCTAssertEqual(target.entries.map(\.reading), source.entries.map(\.reading))
    }

    func test同じ表記を読み込むと上書きして増やさない() throws {
        let store = LocalDictionaryStore(fileURL: fileURL)
        store.add(term: "Slack", reading: nil, wrongForms: ["スラック"])
        let incoming = Data(#"[{"term": "Slack", "wrong_forms": ["すらっく"]}]"#.utf8)

        try store.importData(incoming)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.wrongForms, ["すらっく"])
    }

    /// 人が手で書いた辞書（term だけ）も読める。
    func testtermだけの辞書を読み込める() throws {
        let store = LocalDictionaryStore(fileURL: fileURL)
        try store.importData(Data(#"[{"term": "TypeScript"}]"#.utf8))

        XCTAssertEqual(store.entries.map(\.term), ["TypeScript"])
        XCTAssertEqual(store.entries.first?.wrongForms, [])
    }

    func test認識ヒントは上限の語数までで0なら空() {
        let store = LocalDictionaryStore(fileURL: fileURL)
        for term in ["A", "B", "C"] { store.add(term: term, reading: nil, wrongForms: []) }

        XCTAssertEqual(store.whisperPrompt(limit: 0), "")
        XCTAssertEqual(store.whisperPrompt(limit: 2).components(separatedBy: "、").count, 2)
        XCTAssertEqual(store.whisperPrompt(limit: 10).components(separatedBy: "、").count, 3)
    }

    /// ⚠️ 読めなかったファイルを空の辞書で潰さない。
    func test壊れたファイルは上書きしない() throws {
        let broken = Data("{ これは JSON ではない".utf8)
        try broken.write(to: fileURL)

        let store = LocalDictionaryStore(fileURL: fileURL)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastError)

        store.add(term: "Slack", reading: nil, wrongForms: [])
        XCTAssertEqual(try Data(contentsOf: fileURL), broken)
    }
}
