import XCTest
@testable import AbVoiceLocal

/// キーの押し方と、録音の開始・停止の対応。
/// ⚠️ 長押しの判定は 0.3 秒後にメインスレッドで確定するので、実際に待って確かめる。
final class HotkeyMonitorTests: XCTestCase {
    private var monitor: HotkeyMonitor!
    private var recording = false
    private var starts = 0
    private var commandStarts = 0
    private var stops = 0

    override func setUp() {
        super.setUp()
        monitor = HotkeyMonitor()
        recording = false
        starts = 0
        commandStarts = 0
        stops = 0
        monitor.isRecording = { [unowned self] in recording }
        monitor.onStart = { [unowned self] in starts += 1; recording = true }
        monitor.onStartCommand = { [unowned self] in commandStarts += 1; recording = true }
        monitor.onStop = { [unowned self] in stops += 1; recording = false }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: コマンドキー

    func testコマンドキーを短く押して離しても録音は止まらない() {
        monitor.handleKeyDown(isCommand: true)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.5)

        XCTAssertEqual(commandStarts, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(recording)
    }

    func testコマンドキーを短く押したあともう一度押すと止まる() {
        monitor.handleKeyDown(isCommand: true)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.5)

        monitor.handleKeyDown(isCommand: true)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.05)

        XCTAssertEqual(commandStarts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(recording)
    }

    func testコマンドキーを長押しすると離したところで止まる() {
        monitor.handleKeyDown(isCommand: true)
        wait(0.45)
        monitor.handleKeyUp()
        wait(0.05)

        XCTAssertEqual(commandStarts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(recording)
    }

    /// 口述を「押しっぱなし」にしていても、コマンドキーの短押しはトグルになる。
    func testコマンドキーの短押しは録音モードに関係なくトグル() {
        monitor.configure(keyCode: 49, modifiers: 0, mode: .pushToTalk)
        monitor.handleKeyDown(isCommand: true)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.5)

        XCTAssertEqual(stops, 0)
        XCTAssertTrue(recording)
    }

    // MARK: 口述キー（今までどおり）

    func test押しっぱなしモードの口述キーはすぐ離しても止まる() {
        monitor.configure(keyCode: 49, modifiers: 0, mode: .pushToTalk)
        monitor.handleKeyDown(isCommand: false)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.05)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func test自動モードの口述キーは短押しでトグルし長押しは離して止まる() {
        monitor.configure(keyCode: 49, modifiers: 0, mode: .auto)
        monitor.handleKeyDown(isCommand: false)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.5)
        XCTAssertEqual(stops, 0)

        monitor.handleKeyDown(isCommand: false)
        wait(0.05)
        monitor.handleKeyUp()
        wait(0.05)
        XCTAssertEqual(stops, 1)

        monitor.handleKeyDown(isCommand: false)
        wait(0.45)
        monitor.handleKeyUp()
        wait(0.05)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
    }
}
