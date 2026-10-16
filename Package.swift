// swift-tools-version: 6.0
import PackageDescription

// AbVoice Local — この Mac の中だけで動く音声入力アプリ
//
// .xcodeproj を持たず SwiftPM のみでビルドする。
// .app バンドルの組み立てと codesign は build.sh が行う。
let package = Package(
    name: "AbVoiceLocal",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 内蔵の文字起こし（WhisperKit）。モデルはアプリに同梱せず、初回に取得する。
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0")
    ],
    targets: [
        .executableTarget(
            name: "AbVoiceLocal",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/AbVoice",
            swiftSettings: [
                // 録音・イベントタップ・AX API は MainActor 外から呼ばれる箇所が多く、
                // Swift 6 の厳格な分離モデルと相性が悪いため v5 モードで書く。
                .swiftLanguageMode(.v5)
            ]
        ),
        // ⚠️ ローカルで `swift test` を回すだけ。CI には載せない（macOS runner の消費が大きい）。
        .testTarget(
            name: "AbVoiceTests",
            dependencies: ["AbVoiceLocal"],
            path: "Tests/AbVoiceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
