import XCTest
@testable import AbVoiceLocal

final class CommandParserTests: XCTestCase {
    private let slack = AppTarget(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    private let chrome = AppTarget(bundleID: "com.google.Chrome", name: "Google Chrome")
    private let finder = AppTarget(bundleID: "com.apple.finder", name: "Finder")

    private var candidates: [CommandParser.Candidate] {
        [
            .init(phrase: "Slack", target: slack),
            .init(phrase: "スラック", target: slack),
            .init(phrase: "Google Chrome", target: chrome),
            .init(phrase: "Chrome", target: chrome),
            .init(phrase: "クローム", target: chrome),
            .init(phrase: "ブラウザ", target: chrome),
            .init(phrase: "ファインダー", target: finder),
        ]
    }

    private func parse(_ text: String) -> [WindowCommand] {
        CommandParser.parse(text, candidates: candidates)
    }

    // MARK: 対象なし（前面のウィンドウ）

    func testPlacementWithoutTarget() {
        XCTAssertEqual(parse("右半分にして"), [WindowCommand(action: .rightHalf, target: nil)])
        XCTAssertEqual(parse("左に寄せて。"), [WindowCommand(action: .leftHalf, target: nil)])
        XCTAssertEqual(parse("上半分にして"), [WindowCommand(action: .topHalf, target: nil)])
        XCTAssertEqual(parse("下半分にして"), [WindowCommand(action: .bottomHalf, target: nil)])
        XCTAssertEqual(parse("最大化して"), [WindowCommand(action: .maximize, target: nil)])
        XCTAssertEqual(parse("これを最大化して"), [WindowCommand(action: .maximize, target: nil)])
        XCTAssertEqual(parse("真ん中に置いて"), [WindowCommand(action: .center, target: nil)])
        XCTAssertEqual(parse("センターに"), [WindowCommand(action: .center, target: nil)])
        XCTAssertEqual(parse("元のサイズに戻して"), [WindowCommand(action: .restore, target: nil)])
        XCTAssertEqual(parse("最小化して"), [WindowCommand(action: .minimize, target: nil)])
    }

    func testMaximizeAndMinimizeAreDistinct() {
        XCTAssertEqual(parse("最大化").first?.action, .maximize)
        XCTAssertEqual(parse("最小化").first?.action, .minimize)
    }

    // MARK: 対象あり

    func testActivate() {
        XCTAssertEqual(parse("Chromeを前に出して"), [WindowCommand(action: .activate, target: chrome)])
        XCTAssertEqual(parse("ブラウザを開いて"), [WindowCommand(action: .activate, target: chrome)])
        XCTAssertEqual(parse("ブラウザーを最前面に持ってきて"), [WindowCommand(action: .activate, target: chrome)])
        XCTAssertEqual(parse("スラックに切り替えて"), [WindowCommand(action: .activate, target: slack)])
    }

    func testAppNameOnlyMeansActivate() {
        XCTAssertEqual(parse("Slack"), [WindowCommand(action: .activate, target: slack)])
        XCTAssertEqual(parse("スラック。"), [WindowCommand(action: .activate, target: slack)])
    }

    func testPlacementWithTarget() {
        XCTAssertEqual(parse("Slack を右半分にして"), [WindowCommand(action: .rightHalf, target: slack)])
        XCTAssertEqual(parse("ｓｌａｃｋを右半分に出して"), [WindowCommand(action: .rightHalf, target: slack)])
        XCTAssertEqual(parse("スラックを隠して"), [WindowCommand(action: .hide, target: slack)])
        XCTAssertEqual(parse("ファインダーを最大化"), [WindowCommand(action: .maximize, target: finder)])
    }

    func testLongNameWinsOverShortName() {
        // 「Google Chrome」の中の「Chrome」を 2 つ目のアプリとして数えない。
        XCTAssertEqual(parse("Google Chrome を左半分に"), [WindowCommand(action: .leftHalf, target: chrome)])
    }

    // MARK: 隣の画面

    func testMoveToDisplay() {
        XCTAssertEqual(parse("隣の画面に移して"), [WindowCommand(action: .moveToDisplay, target: nil, display: .next)])
        XCTAssertEqual(
            parse("別のディスプレイに移動して"), [WindowCommand(action: .moveToDisplay, target: nil, display: .next)]
        )
        XCTAssertEqual(
            parse("Slackを隣のモニターに出して"), [WindowCommand(action: .moveToDisplay, target: slack, display: .next)]
        )
        XCTAssertEqual(
            parse("スラックを一番右のディスプレイに表示するようにしてください"),
            [WindowCommand(action: .moveToDisplay, target: slack, display: .right)]
        )
        XCTAssertEqual(
            parse("左のモニターに移して"), [WindowCommand(action: .moveToDisplay, target: nil, display: .left)]
        )
    }

    func testPlacementOnDisplay() {
        XCTAssertEqual(
            parse("スラックを一番右のモニターに全面表示できるようにして"),
            [WindowCommand(action: .maximize, target: slack, display: .right)]
        )
        // 「真ん中のモニター」の「真ん中」を「中央に置く」と取り違えない。
        XCTAssertEqual(
            parse("Chromeを真ん中のモニターの右半分にして"),
            [WindowCommand(action: .rightHalf, target: chrome, display: .center)]
        )
        // 意味が決まらない組み合わせは実行しない。
        XCTAssertEqual(parse("Slackを隣の画面で最小化して"), [])
    }

    func testQuarters() {
        XCTAssertEqual(parse("Chromeを右上1/4にして"), [WindowCommand(action: .topRightQuarter, target: chrome)])
        XCTAssertEqual(parse("左下にして"), [WindowCommand(action: .bottomLeftQuarter, target: nil)])
        XCTAssertEqual(parse("右下4分の1"), [WindowCommand(action: .bottomRightQuarter, target: nil)])
        XCTAssertEqual(parse("Slackを左上に"), [WindowCommand(action: .topLeftQuarter, target: slack)])
    }

    func testMaximizeWordings() {
        XCTAssertEqual(parse("Slackを画面全体に表示するようにして"), [WindowCommand(action: .maximize, target: slack)])
        XCTAssertEqual(parse("Chromeを前面に持ってきて"), [WindowCommand(action: .activate, target: chrome)])
    }

    // MARK: 知らない名前（前面のウィンドウを巻き込まない）

    func testUnknownAppNameGoesToLLM() {
        // 「ズーム」は候補に無い。前面のアプリを動かしてはいけない。
        XCTAssertEqual(parse("ズームを右半分にして"), [])
        XCTAssertEqual(parse("ズームを隠して"), [])
        XCTAssertEqual(parse("ズーム右半分に表示するようにして"), [])
        // 対象を言っていない・代名詞なら前面のウィンドウ。
        XCTAssertEqual(parse("このウィンドウを右半分にして"), [WindowCommand(action: .rightHalf, target: nil)])
    }

    // MARK: 解釈しない（LLM に回す）

    func testUnknownGoesToLLM() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("今日はいい天気ですね"), [])
        // 何を前に出すのか分からない。
        XCTAssertEqual(parse("前に出して"), [])
        // アプリが 2 つ = 複数の操作。
        XCTAssertEqual(parse("Chromeを左、Slackを右にして"), [])
        // 操作が 2 つ。
        XCTAssertEqual(parse("最大化して真ん中に置いて"), [])
        // アプリ名を含むだけの文章。
        XCTAssertEqual(parse("Slackの通知がうるさいんだよね"), [])
    }

    func testUnknownAppNameKeepsTheAction() {
        // 操作はパターン照合で確定させ、名前だけを LLM に聞く。
        XCTAssertEqual(
            CommandParser.analyze("ズームを右上にして", candidates: candidates),
            .needsTarget(WindowCommand(action: .topRightQuarter, target: nil), spokenName: "ズム")
        )
        XCTAssertEqual(
            CommandParser.analyze("ズームを右のモニターで最大化して", candidates: candidates),
            .needsTarget(WindowCommand(action: .maximize, target: nil, display: .right), spokenName: "ズム")
        )
        XCTAssertEqual(
            CommandParser.analyze("ターミナルを開いて", candidates: candidates),
            .needsTarget(WindowCommand(action: .activate, target: nil), spokenName: "タミナル")
        )
        XCTAssertEqual(CommandParser.analyze("ズームをなんとかして", candidates: candidates), .unknown)
    }

    @MainActor
    func testWordPhrases() {
        let code = AppTarget(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
        let word = AppTarget(bundleID: "com.microsoft.Word", name: "Microsoft Word")
        let excel = AppTarget(bundleID: "com.microsoft.Excel", name: "Microsoft Excel")
        let phrases = AppAliasStore.wordPhrases(for: [chrome, code, word, excel, slack])
        XCTAssertTrue(phrases.contains(.init(phrase: "chrome", target: chrome)))
        XCTAssertTrue(phrases.contains(.init(phrase: "code", target: code)))
        // 2 つのアプリに出てくる語は使わない。
        XCTAssertFalse(phrases.contains { $0.phrase == "microsoft" })
        // 1 語の名前は表示名そのもので当たるので、ここには出さない。
        XCTAssertFalse(phrases.contains { $0.target == slack })
    }

    func testValidateApp() {
        XCTAssertEqual(CommandInterpreter.validateApp(#"{"app":"slack"}"#, targets: [slack, chrome]), slack)
        XCTAssertNil(CommandInterpreter.validateApp(#"{"app":null}"#, targets: [slack]))
        XCTAssertNil(CommandInterpreter.validateApp(#"{"app":"Zoom"}"#, targets: [slack]))
    }

    // MARK: LLM の出力の検証

    func testValidateAcceptsKnownActionsAndApps() {
        let json = #"{"commands":[{"action":"leftHalf","app":"google chrome"},{"action":"rightHalf","app":"Slack"}]}"#
        XCTAssertEqual(
            CommandInterpreter.validate(json, targets: [slack, chrome]),
            [WindowCommand(action: .leftHalf, target: chrome), WindowCommand(action: .rightHalf, target: slack)]
        )
        XCTAssertEqual(
            CommandInterpreter.validate(#"{"commands":[{"action":"maximize","app":null}]}"#, targets: [slack]),
            [WindowCommand(action: .maximize, target: nil)]
        )
    }

    func testValidateRejectsAnythingSuspicious() {
        // 空
        XCTAssertNil(CommandInterpreter.validate(#"{"commands":[]}"#, targets: [slack]))
        // 知らない操作
        XCTAssertNil(CommandInterpreter.validate(#"{"commands":[{"action":"quit","app":"Slack"}]}"#, targets: [slack]))
        // 候補に無いアプリ
        XCTAssertNil(CommandInterpreter.validate(#"{"commands":[{"action":"hide","app":"Terminal"}]}"#, targets: [slack]))
        // 1 つでもおかしければ全体を捨てる
        XCTAssertNil(CommandInterpreter.validate(
            #"{"commands":[{"action":"hide","app":"Slack"},{"action":"explode","app":null}]}"#, targets: [slack]
        ))
        // 対象の無い前面化
        XCTAssertNil(CommandInterpreter.validate(#"{"commands":[{"action":"activate","app":null}]}"#, targets: [slack]))
        // JSON ではない
        XCTAssertNil(CommandInterpreter.validate("Slack を右半分にします", targets: [slack]))
        // 知らないディスプレイ
        XCTAssertNil(CommandInterpreter.validate(
            #"{"commands":[{"action":"maximize","app":"Slack","display":"top"}]}"#, targets: [slack]
        ))
        // 行き先の無い移動
        XCTAssertNil(CommandInterpreter.validate(
            #"{"commands":[{"action":"moveToDisplay","app":"Slack","display":null}]}"#, targets: [slack]
        ))
    }

    func testValidateDisplay() {
        XCTAssertEqual(
            CommandInterpreter.validate(
                #"{"commands":[{"action":"maximize","app":"Slack","display":"right"}]}"#, targets: [slack]
            ),
            [WindowCommand(action: .maximize, target: slack, display: .right)]
        )
        // ディスプレイを指定できない操作に付いてきたぶんは無視する。
        XCTAssertEqual(
            CommandInterpreter.validate(
                #"{"commands":[{"action":"hide","app":"Slack","display":"left"}]}"#, targets: [slack]
            ),
            [WindowCommand(action: .hide, target: slack)]
        )
    }

    // MARK: 配置先の計算

    @MainActor
    func testTargetRect() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            WindowController.targetRect(for: .rightHalf, current: current, visible: visible),
            CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        )
        // NSScreen は上向きが正。上半分は y = 500 から。
        XCTAssertEqual(
            WindowController.targetRect(for: .topHalf, current: current, visible: visible),
            CGRect(x: 0, y: 500, width: 2000, height: 500)
        )
        XCTAssertEqual(
            WindowController.targetRect(for: .center, current: current, visible: visible),
            CGRect(x: 600, y: 200, width: 800, height: 600)
        )
        XCTAssertNil(WindowController.targetRect(for: .minimize, current: current, visible: visible))
    }

    @MainActor
    func testMovedKeepsRelativePlacement() {
        let from = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let to = CGRect(x: -1000, y: 200, width: 1000, height: 500)
        // 右半分にあったものは、移動先でも右半分。
        XCTAssertEqual(
            WindowController.moved(CGRect(x: 1000, y: 0, width: 1000, height: 1000), from: from, to: to),
            CGRect(x: -500, y: 200, width: 500, height: 500)
        )
    }
}
