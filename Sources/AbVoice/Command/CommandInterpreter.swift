import Foundation

struct CommandInterpreterConfig {
    var ollamaURL: URL?
    var model: String
    var openAIModel: String
    var openAIKey: String?
}

/// パターン照合で解釈できなかった文を LLM でコマンドにする（2 段目）。
///
/// ⚠️ `FormatService` とは独立させる。整形とコマンドではプロンプトも出力形式も違う。
/// ⚠️ LLM の出力は信用しない。知らない操作・候補に無いアプリが 1 つでもあれば全体を捨てる
///    （LLM が作ったアプリ名で起動を試みない）。
enum CommandInterpreter {
    /// 1 回の発話で受け付けるコマンドの上限。
    static let maxCommands = 4

    static let systemPrompt = """
    あなたは Mac のウィンドウ操作の音声コマンドを解釈します。
    入力は音声認識の生テキストです。JSON だけを返してください。

    形式: {"commands": [{"action": "<操作>", "app": "<アプリ名または null>", "display": "<ディスプレイまたは null>"}]}

    操作:
    - activate: アプリを前面に出す・開く・切り替える（app が必須）
    - maximize: 画面いっぱいに広げる・全画面で表示する
    - leftHalf / rightHalf / topHalf / bottomHalf: 画面の左・右・上・下の半分に置く
    - topLeftQuarter / topRightQuarter / bottomLeftQuarter / bottomRightQuarter: 画面の左上・右上・左下・右下の 4 分の 1 に置く
    - center: 画面の中央に置く
    - restore: 元の位置とサイズに戻す
    - minimize: 最小化する・しまう
    - hide: アプリを隠す
    - moveToDisplay: 大きさを変えずに別のディスプレイへ移す（display が必須）

    ディスプレイ（モニター・画面のどれで行うかを言ったときだけ指定する）:
    - left: 左の（一番左の）ディスプレイ
    - right: 右の（一番右の）ディスプレイ
    - center: 真ん中の・メインのディスプレイ
    - next: 隣の・別の・次のディスプレイ
    - 「右のモニターに表示して」は moveToDisplay + right。rightHalf ではない
    - 「右のモニターで最大化」は maximize + right
    - ディスプレイを言っていないときは null

    規則:
    - app は「使えるアプリ」に書かれた名前をそのまま使う。一覧に無いアプリは使わない
    - 「これ」「このウィンドウ」のように対象を言っていないときは app を null にする
    - ウィンドウ操作と関係ない発話、解釈できない発話は {"commands": []} を返す
    - 閉じる・終了する・削除するなど、上に無い操作は {"commands": []} を返す
    """

    /// - Returns: 解釈できたコマンド。できなければ nil。
    static func interpret(
        _ text: String, targets: [AppTarget], config: CommandInterpreterConfig
    ) async -> (commands: [WindowCommand], model: String)? {
        let prompt = "使えるアプリ:\n" + targets.map { "- \($0.name)" }.joined(separator: "\n")
            + "\n\n音声認識テキスト:\n\(text)"

        if let raw = try? await askOllama(prompt, system: systemPrompt, schema: responseSchema, config: config),
           let commands = validate(raw, targets: targets) {
            return (commands, config.model)
        }
        if let raw = try? await askOpenAI(prompt, system: systemPrompt, config: config),
           let commands = validate(raw, targets: targets) {
            return (commands, config.openAIModel)
        }
        return nil
    }

    // MARK: アプリ名だけを聞く

    static let appNamePrompt = """
    音声認識で聞き取った「アプリの呼び名」が、一覧のどのアプリを指すかを答えます。JSON だけを返してください。

    形式: {"app": "<一覧にある名前そのまま、または null>"}

    規則:
    - カタカナ読み（スラック = Slack）、略称、一般的な呼び方（ターミナル、エディタ、メール など）を考慮する
    - 音声認識の聞き間違いで 1〜2 文字ずれていることがある
    - 一覧に当てはまるものが無い、または確信が持てないときは null
    """

    /// 操作はパターン照合で分かっていて、アプリの呼び名だけが分からないときに使う。
    static func resolveApp(
        _ spokenName: String, targets: [AppTarget], config: CommandInterpreterConfig
    ) async -> (target: AppTarget, model: String)? {
        let prompt = "アプリの一覧:\n" + targets.map { "- \($0.name)" }.joined(separator: "\n")
            + "\n\n聞き取った呼び名: \(spokenName)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["app": ["type": ["string", "null"]]],
            "required": ["app"],
        ]

        if let raw = try? await askOllama(prompt, system: appNamePrompt, schema: schema, config: config),
           let target = validateApp(raw, targets: targets) {
            return (target, config.model)
        }
        if let raw = try? await askOpenAI(prompt, system: appNamePrompt, config: config),
           let target = validateApp(raw, targets: targets) {
            return (target, config.openAIModel)
        }
        return nil
    }

    /// ⚠️ 一覧に無い名前を返してきたら捨てる。
    static func validateApp(_ json: String, targets: [AppTarget]) -> AppTarget? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["app"] as? String
        else { return nil }
        return targets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// LLM の返した JSON を検証してコマンドにする。1 つでもおかしければ nil。
    static func validate(_ json: String, targets: [AppTarget]) -> [WindowCommand]? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["commands"] as? [[String: Any]],
              !items.isEmpty, items.count <= maxCommands
        else { return nil }

        var commands: [WindowCommand] = []
        for item in items {
            guard let rawAction = item["action"] as? String,
                  let action = WindowCommand.Action(rawValue: rawAction)
            else { return nil }

            var target: AppTarget?
            if let name = item["app"] as? String, !name.isEmpty {
                guard let found = targets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                else { return nil }
                target = found
            }
            if action == .activate, target == nil { return nil }

            var display: DisplaySelector?
            if let rawDisplay = item["display"] as? String, !rawDisplay.isEmpty {
                guard let selector = DisplaySelector(rawValue: rawDisplay) else { return nil }
                // ディスプレイを指定できない操作に付いてきたぶんは無視する。
                display = action.acceptsDisplay ? selector : nil
            }
            if action == .moveToDisplay, display == nil { return nil }
            commands.append(WindowCommand(action: action, target: target, display: display))
        }
        return commands
    }

    // MARK: Ollama

    private static var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "commands": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "action": ["type": "string", "enum": WindowCommand.Action.allCases.map(\.rawValue)],
                            "app": ["type": ["string", "null"]],
                            "display": [
                                "type": ["string", "null"],
                                "enum": DisplaySelector.allCases.map(\.rawValue) + [NSNull()] as [Any],
                            ],
                        ],
                        "required": ["action", "app", "display"],
                    ],
                ],
            ],
            "required": ["commands"],
        ]
    }

    private static func askOllama(
        _ prompt: String, system: String, schema: [String: Any], config: CommandInterpreterConfig
    ) async throws -> String {
        guard let url = config.ollamaURL else { throw HTTPError.notConfigured("Ollama の URL") }
        let payload: [String: Any] = [
            "model": config.model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "keep_alive": "30m",
            "format": schema,
            "options": ["temperature": 0, "num_predict": 256],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = json["response"] as? String
        else { throw HTTPError.decoding("response がありません") }
        return value
    }

    // MARK: OpenAI（フォールバック。課金される）

    private static func askOpenAI(
        _ prompt: String, system: String, config: CommandInterpreterConfig
    ) async throws -> String {
        guard let key = config.openAIKey, !key.isEmpty else {
            throw HTTPError.notConfigured("OpenAI API キー")
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw HTTPError.badURL }

        let payload: [String: Any] = [
            "model": config.openAIModel,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains(response.httpStatusCode) else {
            throw HTTPError.status(response.httpStatusCode, String(data: data, encoding: .utf8))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw HTTPError.decoding("choices[0].message.content がありません") }
        return content
    }
}
