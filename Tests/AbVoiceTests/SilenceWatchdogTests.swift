import XCTest
@testable import AbVoiceLocal

/// 無音監視の「声」のしきい値と停止の判定。
/// ⚠️ 開始直後 0.3 秒がノイズフロアの計測窓なので、実際に待ってから声の音量を渡す。
final class SilenceWatchdogTests: XCTestCase {
    private func passCalibration(_ watchdog: SilenceWatchdog, noise: Float) {
        watchdog.start()
        watchdog.feed(level: noise)
        watchdog.feed(level: noise)
        Thread.sleep(forTimeInterval: 0.35)
    }

    /// 計測窓に開始音や喋り出しが入っても、普通の発話（0.01〜0.03）を声として扱う（2026-09-04 / 09-08 の実ログ）。
    func testノイズフロアが上振れしても普通の発話は声とみなす() {
        let watchdog = SilenceWatchdog(threshold: 30)
        passCalibration(watchdog, noise: 0.0136)

        watchdog.feed(level: 0.02)

        XCTAssertEqual(watchdog.voiceThreshold, 0.010, accuracy: 0.0001)
        XCTAssertTrue(watchdog.didHearVoice)
    }

    func test静かな部屋では下限のしきい値になる() {
        let watchdog = SilenceWatchdog(threshold: 30)
        passCalibration(watchdog, noise: 0.0005)

        watchdog.feed(level: 0.003)

        XCTAssertEqual(watchdog.voiceThreshold, 0.004, accuracy: 0.0001)
        XCTAssertFalse(watchdog.didHearVoice)
    }

    func test上振れした部屋でも喋り続けている間は止まらず黙ったら止まる() {
        let watchdog = SilenceWatchdog(threshold: 0.3)
        var fired = 0
        watchdog.onTimeout = { fired += 1 }
        passCalibration(watchdog, noise: 0.0136)

        // 0.02 の発話を 0.15 秒ごとに 0.45 秒（しきい値 0.3 秒を超える長さ）続ける
        for _ in 0..<4 {
            watchdog.feed(level: 0.02)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertEqual(fired, 0)

        // 黙る
        watchdog.feed(level: 0.002)
        Thread.sleep(forTimeInterval: 0.35)
        watchdog.feed(level: 0.002)
        XCTAssertEqual(fired, 1)
    }

    func test喋り出す前の沈黙では止まらない() {
        let watchdog = SilenceWatchdog(threshold: 0.2)
        var fired = 0
        watchdog.onTimeout = { fired += 1 }
        passCalibration(watchdog, noise: 0.001)

        watchdog.feed(level: 0.001)
        Thread.sleep(forTimeInterval: 0.3)
        watchdog.feed(level: 0.001)

        XCTAssertEqual(fired, 0)
    }
}
