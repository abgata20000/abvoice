import AppKit
import ApplicationServices

enum WindowError: LocalizedError {
    case notTrusted
    case appNotFound(String)
    case notRunning(String)
    case noWindow(String)
    case fullScreen(String)
    case noOtherDisplay
    case nothingToRestore
    case noTarget

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "アクセシビリティ権限が無いためウィンドウを動かせません"
        case .appNotFound(let name): return "\(name) が見つかりません"
        case .notRunning(let name): return "\(name) は起動していません"
        case .noWindow(let name): return "\(name) のウィンドウがありません"
        case .fullScreen(let name): return "\(name) はフルスクリーン中のため動かせません"
        case .noOtherDisplay: return "移動先のディスプレイがありません"
        case .nothingToRestore: return "戻す位置を覚えていません"
        case .noTarget: return "対象のアプリが分かりません"
        }
    }
}

/// AX API でウィンドウを動かす。音声にも LLM にも依存しない。
///
/// ⚠️ 座標系が 2 つある。AX は「主画面の左上が原点・下向きが正」、
///    `NSScreen` は「主画面の左下が原点・上向きが正」。配置先は `NSScreen` で計算し、
///    書き込む直前に AX の座標へ変換する。
@MainActor
enum WindowController {
    /// 配置を変える直前のフレーム（AX 座標）。「元に戻して」用。
    /// ⚠️ メモリ上にだけ持つ。アプリを再起動したら忘れてよい。
    private static var savedFrames: [AXUIElement: CGRect] = [:]

    // MARK: 前面に出す

    /// アプリを前面に出す。起動していなければ起動する。
    ///
    /// ⚠️ `NSRunningApplication.activate()` ではなく `openApplication` を使う。
    ///    常駐アプリ（前面にいない）からの activate は macOS 14 以降で効かないことがある。
    static func activate(_ target: AppTarget) async throws -> NSRunningApplication {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first
        guard let url = running?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID)
        else { throw WindowError.appNotFound(target.name) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        // 起動直後はウィンドウがまだ無い。出てくるまで最大 3 秒待つ。
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<30 {
            if mainWindow(of: element) != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let window = mainWindow(of: element), bool(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        return app
    }

    // MARK: 配置

    /// `activate` 以外の操作を 1 つ実行する。
    /// - Parameter display: 配置先のディスプレイ。nil ならいまウィンドウがある画面。
    /// - Returns: 何かを変えたか。「もうその画面にいる」ときは false
    ///   （何も起きなかったのに「実行しました」と出さないため）。
    @discardableResult
    static func perform(
        _ action: WindowCommand.Action, display: DisplaySelector? = nil, on app: NSRunningApplication
    ) throws -> Bool {
        guard AXIsProcessTrusted() else { throw WindowError.notTrusted }
        let name = app.localizedName ?? "アプリ"

        if action == .hide {
            app.hide()
            return true
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = mainWindow(of: element) else { throw WindowError.noWindow(name) }

        if action == .minimize {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return true
        }

        // ⚠️ フルスクリーンは別の Space にいるので動かせない。v1 は解除せずに知らせる。
        if bool(window, "AXFullScreen") == true { throw WindowError.fullScreen(name) }
        guard let current = frame(of: window) else { throw WindowError.noWindow(name) }

        if action == .restore {
            guard let saved = savedFrames[window] else { throw WindowError.nothingToRestore }
            place(window, app: element, at: saved)
            savedFrames[window] = nil
            return true
        }

        let from = screen(containing: current)
        var to = from
        if let display {
            guard let selected = screen(for: display, from: from) else { throw WindowError.noOtherDisplay }
            to = selected
        }

        let rect: CGRect
        if action == .moveToDisplay {
            guard to != from else { return false } // もうその画面にいる
            rect = moved(flipped(current), from: from.visibleFrame, to: to.visibleFrame)
        } else {
            guard let target = targetRect(for: action, current: flipped(current), visible: to.visibleFrame)
            else { return false }
            rect = target
        }
        savedFrames[window] = current
        place(window, app: element, at: flipped(rect))
        return true
    }

    /// 言われたディスプレイを選ぶ。左右は画面の並び（x 座標）で決める。1 枚しか無ければ nil。
    private static func screen(for selector: DisplaySelector, from current: NSScreen) -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return nil }
        let sorted = screens.sorted { $0.frame.minX < $1.frame.minX }
        switch selector {
        case .left: return sorted.first
        case .right: return sorted.last
        case .center: return sorted.count >= 3 ? sorted[sorted.count / 2] : screens.first
        case .next:
            let index = screens.firstIndex(of: current) ?? 0
            return screens[(index + 1) % screens.count]
        }
    }

    /// 配置先（`NSScreen` の座標）。配置系でない操作は nil。
    static func targetRect(for action: WindowCommand.Action, current: CGRect, visible: CGRect) -> CGRect? {
        let halfWidth = visible.width / 2
        let halfHeight = visible.height / 2
        switch action {
        case .maximize:
            return visible
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
        case .rightHalf:
            return CGRect(x: visible.midX, y: visible.minY, width: halfWidth, height: visible.height)
        case .topHalf:
            // NSScreen は上向きが正。上半分は midY から。
            return CGRect(x: visible.minX, y: visible.midY, width: visible.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfHeight)
        // NSScreen は上向きが正。「上」は midY から。
        case .topLeftQuarter:
            return CGRect(x: visible.minX, y: visible.midY, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: visible.midX, y: visible.midY, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: visible.midX, y: visible.minY, width: halfWidth, height: halfHeight)
        case .center:
            let width = min(current.width, visible.width)
            let height = min(current.height, visible.height)
            return CGRect(
                x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height
            )
        default:
            return nil
        }
    }

    /// 画面内の相対位置と相対サイズを保ったまま、別の画面へ移した矩形を返す。
    static func moved(_ rect: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return to }
        let width = min(to.width, rect.width / from.width * to.width)
        let height = min(to.height, rect.height / from.height * to.height)
        let x = to.minX + (rect.minX - from.minX) / from.width * to.width
        let y = to.minY + (rect.minY - from.minY) / from.height * to.height
        return CGRect(
            x: min(max(x, to.minX), to.maxX - width),
            y: min(max(y, to.minY), to.maxY - height),
            width: width, height: height
        )
    }

    // MARK: 座標

    /// AX ⇔ NSScreen の変換。上下を主画面の高さで折り返すだけなので、同じ関数で往復できる。
    private static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// ウィンドウの中心がある画面。
    private static func screen(containing axFrame: CGRect) -> NSScreen {
        let rect = flipped(axFrame)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: AX の読み書き

    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        if let window = element(app, kAXFocusedWindowAttribute) { return window }
        if let window = element(app, kAXMainWindowAttribute) { return window }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement]
        else { return nil }
        return windows.first
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = value(window, kAXPositionAttribute),
              let sizeValue = value(window, kAXSizeAttribute),
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// ⚠️ サイズ → 位置 → サイズの順で書く。画面をまたぐ移動で先に位置を書くと、
    ///    移動先に収まらないサイズのままになり、アプリ側が勝手に縮めることがある。
    /// ⚠️ `AXEnhancedUserInterface` が true のアプリ（Chrome・Electron 系）は、位置とサイズの変更が
    ///    アニメーションになって遅い・ずれる。書き込みの間だけ切る。
    /// ⚠️ 書いたとおりにならないアプリがある（ターミナルは文字セル刻み）。エラーにはしない。
    private static func place(_ window: AXUIElement, app: AXUIElement, at axRect: CGRect) {
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        defer {
            if enhanced {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }

        var origin = axRect.origin
        var size = axRect.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXValue.self)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }
}
