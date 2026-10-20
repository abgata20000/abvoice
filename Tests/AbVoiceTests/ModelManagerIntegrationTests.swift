import XCTest
@testable import AbVoiceLocal

/// アプリと同じ経路で、モデルを取得して読み込めるかを確かめる結合テスト。
/// 実際にインターネットから数百 MB を取得し、`Application Support` の本物の置き場所に保存するので、普段は飛ばす。
///
/// 走らせるとき:
///   ABVOICE_TEST_DOWNLOAD=1 swift test --filter ModelManagerIntegrationTests
@MainActor
final class ModelManagerIntegrationTests: XCTestCase {
    func test取得から読み込みまで通る() async throws {
        guard ProcessInfo.processInfo.environment["ABVOICE_TEST_DOWNLOAD"] == "1" else {
            throw XCTSkip("ABVOICE_TEST_DOWNLOAD=1 のときだけ走る")
        }
        let variant = WhisperModelChoice.light.rawValue
        let manager = ModelManager.shared

        await manager.downloadAndPrepare(variant: variant)

        XCTAssertEqual(manager.status, .ready, "状態: \(manager.statusText)")
        XCTAssertTrue(manager.isDownloaded(variant), "取得済みの印が無い")
        let isLoaded = await WhisperEngine.shared.isLoaded
        XCTAssertTrue(isLoaded)
    }

    /// 取得済みかの判定は、読み込みに使う 3 つのファイルが揃っているかで見る（URL の文字列では比べない）。
    func test本体の3ファイルが揃っているかで判定する() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("abvoice-local-tests-\(UUID().uuidString) with space", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["MelSpectrogram", "AudioEncoder"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true
            )
        }
        XCTAssertFalse(ModelManager.hasModelFiles(in: folder))

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("TextDecoder.mlmodelc"), withIntermediateDirectories: true
        )
        XCTAssertTrue(ModelManager.hasModelFiles(in: folder))
    }
}
