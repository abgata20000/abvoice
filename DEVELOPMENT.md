# 開発する人向け

## 必要なもの

- Apple シリコンの Mac / macOS 14 以上
- Xcode 16 以上（`swift` コマンドとして使うだけ。`.xcodeproj` は持たない）

## ビルド

```bash
./build.sh debug
```

`dist/AbVoice Local.app` ができる。`--install` を付けると `/Applications` にも置く。

- 署名は Developer ID Application → Apple Development → ad-hoc の順に、見つかったもので行う
- ⚠️ ad-hoc だと、ビルドし直すたびにアクセシビリティの許可を付け直すことになる
- ⚠️ 依存ライブラリのリソース（`*.bundle`）を `.app` の `Contents/Resources/` に入れている。
  入れ忘れると、ライブラリがリソースを読みに行った時点でアプリが落ちる

## テスト

```bash
swift test
```

実際の文字起こしモデルを使う結合テスト（`WhisperEngineIntegrationTests`）は、
モデルと音声の場所を環境変数で渡したときだけ走る。渡し方はテストファイルの先頭に書いてある。

CI では Swift のビルドもテストも回さない（macOS の runner は無料枠の消費が大きいため）。

## リリース

### 1 回だけやること

1. Developer ID Application の証明書を入れる（`./scripts/setup-developer-id.sh` が手伝う）
2. 公証の認証情報を Keychain に入れる。App 用パスワードは appleid.apple.com で発行する

```bash
xcrun notarytool store-credentials abvoice-notary --apple-id <Apple ID> --team-id <Team ID>
```

認証情報はリポジトリにも環境変数にも書かない。スクリプトにはプロファイル名だけを渡す。

### 毎回やること

1. `Resources/Info.plist` の `CFBundleShortVersionString`（と `CFBundleVersion`）を上げてコミットする
2. 公証つきの `.dmg` を作り、GitHub Releases に下書きで置く

```bash
NOTARY_PROFILE=abvoice-notary ./scripts/release.sh 0.1.0 --publish
```

3. 別の Mac（できれば一度も入れたことのない Mac）で `.dmg` を落として開き、警告なしで開けることを確かめる
4. GitHub の画面で下書きを公開する

公証なしで流れだけ確かめるときは `--skip-notarize`（できた `.dmg` は配布しない）。

## 構成

| 場所                  | 中身                                                           |
| --------------------- | -------------------------------------------------------------- |
| `Sources/AbVoice/`    | アプリ本体（SwiftPM のターゲット名は `AbVoiceLocal`）          |
| `Engine/`             | 内蔵の文字起こし（WhisperKit）とモデルの取得・読み込み         |
| `Services/`           | 文字起こし・整形・録音から挿入までの流れ（`VoiceCoordinator`） |
| `Store/`              | この Mac のファイルに置く辞書・履歴                            |
| `Command/`            | 音声コマンド（ウィンドウ操作）                                 |
| `Onboarding/`         | 初回の設定                                                     |
| `Tests/AbVoiceTests/` | テスト                                                         |
| `scripts/`            | リリース・公開前チェック・証明書の準備                         |

## 約束

- 外部への送信はゼロが既定。音声やテキストを外に出すのは、本人が設定で OpenAI を選んだときだけ
- 選ばれていないプロバイダへ自動で切り替えない（失敗したら、整形なし・文字起こし失敗として扱う）
- 録音はディスクに保存しない
- 辞書の置き換え（誤変換 → 正しい表記）は、LLM の整形の「後」に行う

## 文字起こしエンジンの癖（実測）

- 取得した直後の 1 回目の読み込みは、Core ML がその Mac 向けに最適化するので数分かかる。2 回目以降は 1 秒前後
- 計算ユニットは既定（Neural Engine）のまま使う。GPU を指定すると圧縮版のモデルでは極端に遅くなる
- 辞書の語をプロンプトに渡すと、直後に終了トークンを出して結果が空になることがある。
  `WhisperEngine` のフィルタで、本文の最初の 1 トークンだけ終了を選ばせないようにしている
- 30 秒を超える録音は、タイムスタンプありで文字起こしする（なしだと 30 秒の区切りで言葉が落ちる）
- 言語の判定はエンコーダをもう 1 回回すので 0.7〜1 秒かかる。3 秒以下の録音のときだけ行う
