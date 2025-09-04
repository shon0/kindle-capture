# kindle-capture

Kindle（macOS アプリ）のページを自動で連続キャプチャし、画像を 1 冊 = 1 PDF に結合するツールです。NotebookLM への投入を想定し、OCR は行いません（NotebookLM が画像 PDF から認識）。

対応: macOS / 依存: shell + AppleScript + Homebrew（img2pdf）

## 特長

- 自動終端検出: 直前画像との完全一致で最終ページを判定し停止（重複は削除）
- 続きから再開: 既存の連番を検出し、途中から継続可能
- 高速 PDF 結合: `img2pdf` で非再圧縮のまま結合
- 日本語タイトル対応: `/` を全角に置換、前後スペースをトリム
- 左開き対応: `DIRECTION=left` で左矢印を送信
- 軽量: 標準の shell と AppleScript のみで動作

## 必要条件とセットアップ

- アクセシビリティ許可: 「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で `ターミナル`（または使用シェル）を許可
- 通知対策: 実行前に「コントロールセンター > 集中モード > おやすみモード」をオン（通知バナーの写り込み防止）。必要に応じて「システム設定 > 集中モード」で自動化

インストール:

```
make install
```

Homebrew の `Brewfile` で `img2pdf` を導入します。

## 使い方（クイックスタート）

1) Kindle で対象の本を開き、ページめくりモードにして先頭ページを表示

2) 集中モードをオンにし、Kindle を最前面のままにする

3) 実行:

```
make run TITLE="<本のタイトル>"
```

- 画像: `out/<タイトル>/shots/page_***.png`
- PDF : `out/<タイトル>/<タイトル>.pdf`

短時間チェック（上限を設定）:

```
MAX_PAGES=5 make run TITLE="テスト本"
```

## 実行時の注意

- フォーカス固定: 実行中は Kindle を最前面・アクティブのままにする（前面アプリへ矢印キー送信）
- 放置推奨: 完了まで他アプリへ切り替えたり、キーボード/マウス操作をしない
- ウィンドウ固定: 移動・リサイズ・ページ設定変更は行わない（キャプチャ範囲が変わるため）
- ディスプレイ: 可能ならメインディスプレイに固定（座標はメイン基準）
- 通知対策: 実行前に集中モード（おやすみモード）をオン
- カーソル: 撮影領域からカーソルを退避（自動終了検出に影響）

## 注意事項・法的留意点

- 本ツールは学習・検証用途のユーティリティです。利用は「個人の私的利用」の範囲に留めてください。
- 対象サービス（Kindle）および Amazon の利用規約・各国の著作権法を必ず遵守してください。コンテンツの第三者への配布・共有・商用利用は行わないでください。
- 本ツールは DRM の回避を目的としたものではありません（画面のスクリーンショットを自動で取得するだけです）。
- 生成物（画像/PDF）の取り扱いは利用者の責任で行ってください。公開・アップロード・二次利用には著作権者の許諾が必要な場合があります。

## 設定（環境変数）

- `INTERVAL`: ページ送り後の待機秒。既定 `0.6`
- `TOP_PAD`/`BOTTOM_PAD`/`LEFT_PAD`/`RIGHT_PAD`: キャプチャ余白（px）
- `ACTIVATE_EVERY`: Nページごとに Kindle を再アクティブ化。既定 `20`
- `DIRECTION`: 左開き対応。`left` で左矢印（既定は右）
- `MAX_PAGES`: 自動検出モードの安全上限。既定 `0`（無制限）
- `KINDLE_BUNDLE_ID`: Kindle のバンドルID。既定 `com.amazon.Kindle`
- `KINDLE_APP_NAME` : Kindle のアプリ名。既定 `Kindle`（`Amazon Kindle` などに変更可）

例:

```
INTERVAL=0.7 TOP_PAD=60 BOTTOM_PAD=60 make run TITLE="テスト本"
```

### PDF のみ再生成

```
make pdf TITLE="<本のタイトル>"
```

## 仕組み（概要）

- フロー: 「送る → 待つ → 撮る」。新規開始時のみ「撮る」から開始してスキップ防止
- ウィンドウ座標は毎回 AppleScript で取得し、`screencapture -R x,y,w,h` で矩形キャプチャ
- 連番再開: 既存の `page_***.png` を検出し、その続き番号から再開
- 自動終端検出: 直前の画像と完全一致したら最終ページとみなして停止（重複画像は削除）
- 動的要素が写ると一致しない場合があるため、必要に応じて `INTERVAL` を長めに調整。安全装置として `MAX_PAGES` を利用可能
- 実行中は `caffeinate -dimsu` でスリープ抑止、開始/終了時に macOS 通知を送信（失敗しても継続）

## Make ターゲット

- `make install`: `brew bundle` で `img2pdf` を導入
- `make run`    : 最終ページまで自動キャプチャ
- `make pdf`    : 画像から PDF を再生成

## FAQ

- 左開きにしたい
  - `DIRECTION=left make run TITLE=...` を使ってください。
- PDF のサイズが大きい
  - `img2pdf` は画像を再圧縮しません。余白（`*_PAD`）を絞るとサイズ削減に有効です。
- 外部ディスプレイだと座標がおかしい
  - macOS の座標原点はメインディスプレイ左上。Kindle はメインディスプレイへ配置推奨。
- アクセシビリティ権限が必要？
  - はい。`System Events` で矢印キーを送るため許可が必要です。
- うまくページが進まない
  - `ACTIVATE_EVERY` を小さく、`INTERVAL` をやや長めに、集中モードをオン、他アプリへの切替を避ける。
- アプリ名やバンドルIDが違う
  - 環境変数で上書き可。例: `KINDLE_BUNDLE_ID=com.amazon.Kindle KINDLE_APP_NAME="Amazon Kindle" make run TITLE="テスト本"`
  - 取得のヒント: `osascript -e 'id of app "Kindle"'` / `mdls -name kMDItemCFBundleIdentifier /Applications/Kindle.app`

## 動作確認

1. `make install`
2. Kindle で先頭ページを表示（ページめくりモード）
3. `make run TITLE="テスト本"`
4. 完了後の確認:
   - 画像: `out/テスト本/shots/page_001.png` 以降が連番で生成
   - PDF : `out/テスト本/テスト本.pdf`

短時間チェック: `MAX_PAGES=5 make run TITLE="テスト本"`
