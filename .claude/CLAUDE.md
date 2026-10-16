# AbVoice Local

この Mac の中だけで動く音声入力アプリ（macOS・Apple シリコン専用）。
喋った内容を文字起こしして、カーソル位置に挿入する。

## このリポジトリの約束

- **外部への送信はゼロが既定。** 音声もテキストも、本人が設定で OpenAI を選んだときにしか外へ出さない
  - 「この Mac の中」を選んだ人の音声を、失敗をきっかけにクラウドへ落とさない
  - 選ばれていないプロバイダへ自動で切り替えない
  - 外向きの通信を足すときは、設定画面と README の「音声の扱い」に必ず書く
- **録音は保存しない。** 文字起こしが済んだら捨てる。失敗時だけ直近 1 件をメモリに持つ（ディスクに書かない）
- **public のリポジトリ。** 内部の IP・ホスト名・運用手順・個人名・非公開リポジトリの設計書や Issue 番号を書かない。
  公開前チェックは `scripts/prepublish-check.sh`（パターンは `scripts/prepublish-patterns.local`。git 管理外）
- **個人用アプリからはコピーで取り込む。** 共有パッケージにしない。取り込んだら `docs/UPSTREAM.md` に記録する
- **CI に Swift のビルドを載せない。** テストは手元で `swift test`、リリースは手元で `scripts/release.sh`
- 保存先・bundle ID・Keychain のサービス名はすべて `jp.abgata.abvoice.local`

## 構成

```
Package.swift            SwiftPM のみ（.xcodeproj は持たない）。ターゲット名は AbVoiceLocal
Sources/AbVoice/
  Audio/  Input/         録音・ホットキー・権限・挿入
  Core/                  設定・保存先・Keychain・ログ
  Engine/                内蔵の文字起こし（WhisperKit）とモデル管理
  Services/              文字起こし・整形・一連の流れ（VoiceCoordinator）
  Store/                 この Mac のファイルに置く辞書・履歴
  Command/               音声コマンド（ウィンドウ操作）
  Onboarding/  UI/       初回の設定・画面
Tests/AbVoiceTests/
Resources/               Info.plist / entitlements / アイコン
build.sh                 開発用（.app を組み立てて署名）
scripts/release.sh       配布用（公証 → .dmg）
```

## よく使うコマンド

```bash
./build.sh debug
```

```bash
swift test
```

## 実装するときの注意

- コメントの「⚠️」は実測に基づく注意書き。理由が分からないまま消さない
- 辞書の置き換え（`wrong_forms`）は必ず LLM 整形の「後」に適用する
- パスワードフィールドにフォーカスがあるときは録音も挿入もしない
- 文字起こしの速度・メモリ・WhisperKit の癖は `docs/OVERVIEW.md` にまとめてある
