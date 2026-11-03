# Auto2048 — LiveContainer 用 2048 自走 tweak

[English README →](README-EN.md)

[LiveContainer](https://github.com/LiveContainer/LiveContainer) で動かす **2048** (`com.ketchapp.2048`) の通常ゲームを自動操作する tweak (dylib) です。
最大 4 手先を探索してスワイプの方向を決めます。**2048 の到達は保証しません。**

- **盤面の自動操作** — 空きマス・単調性・蛇行配置などを見て、合法手の中から 1 手を選びます。
- **速度の切り替え** — ボタンの長押しで `x1` / `x2` / `x4` / `MAX`。
- **状態の表示** — ボタンに `THINK` / `STALE` / `PAUSE` などの状態を出します。意味と対処は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。
- 対象は 2048 **4.0.8** の通常ゲーム (4×4) のみです。チャレンジ・対戦には対応していません。

## 動作確認状況

| 項目 | 状況 |
| --- | --- |
| 実機 (LiveContainer) | v3 で自走を確認。2048 達成を 1 回確認 |
| 2048 のバージョン | 4.0.8 のみ (他のバージョンは未確認) |
| ゲームモード | 通常ゲーム (4×4) のみ |
| 広告・ポップアップ | 検出しません (手動で OFF / ON) |
| ホスト側シミュレーション | 16 回中 11 回が 4096 到達 (平均最大タイル 3,456) |

シミュレーションは試行回数が少なく、実機での到達率を示すものではありません。
実機で確認したのは**作者の環境 1 台**です。別の端末・バージョンでの結果は Issue で教えてもらえると助かります。

## ダウンロード

[Releases](../../releases/latest) から `Auto2048.dylib` を取得してください。
ゲーム本体・IPA は含まれていません。

## 使い方

1. LiveContainer で 2048 の Tweak フォルダに `Auto2048.dylib` を入れて起動します。旧版がある場合は外してください。
2. 通常ゲームを開くと、右下に `AUTO` ボタンが表示されます (起動時は OFF)。

### AUTO ボタン

| 操作 | 動作 |
| --- | --- |
| タップ | ON / OFF |
| 長押し | 速度切り替え (`x1` → `x2` → `x4` → `MAX`) |

- 速度だけが保存され、ON / OFF は保存されません (起動時は常に OFF)。
- `THINK` は探索中、`PAUSE` はゲーム停止中、`STALE` は盤面が変わって探索結果を捨てた状態です。どれも正常な表示です。
- 2048 の達成画面では `PAUSE` になります。AUTO が ON のまま「続ける」を押すと自走が再開します。

### うまく動かないとき

ボタンが出ない、`I_CLASS` や `F_EXC` のまま止まる、広告で止まる、といった症状は
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** にまとめてあります。
表示される状態の意味と、そのとき何をすればよいかが引けます。

## 注意

- 広告やポップアップは完全には検出できません。表示前に AUTO を OFF にし、閉じた後に再開してください。
  広告自体を消したい場合は [LCAB](https://github.com/mar1mo-41414/LCAB) などを併用してください。
- 自動操作でスコアやセーブが変わります。必要なら事前にバックアップしてください。
- チャレンジ・対戦、4×4 以外の盤面、自動リスタート、自動ポップアップ操作には対応していません。
- ゲームの内部クラス・メソッドを使うため、ゲームや LiveContainer の更新で動かなくなる場合があります。
  必要な再署名は使用環境の手順に従ってください。
- ゲーム本体・抽出データ・セーブはこのリポジトリに含めていません。

## ビルド

[Theos](https://theos.dev) と iOS SDK が必要です。

```bash
make FINALPACKAGE=1
```

生成された `Auto2048.dylib` は通常 `.theos/obj/` 以下にあります。環境に応じて署名してください。

`vX.X` 形式のタグを push すると、GitHub Actions が macOS 上でビルドし、その dylib を Release に添付します。
リポジトリにバイナリは置いていません (配布は Releases のアセットのみ)。

## テスト

Theos は不要です (ホストの C コンパイラだけで動きます)。

```bash
make test        # 単体テスト + 10,000 盤面の移動処理比較
make simulate    # 簡易シミュレーション (3 ゲーム × 5,000 手。数分かかります)
```

個別に実行する場合:

```bash
cc -O2 -Wall -Wextra tests/solver_test.c Sources/Solver.c -lm -o /tmp/solver-test && /tmp/solver-test
cc -O2 -Wall -Wextra tests/internal_test.c -lm -o /tmp/internal-test && /tmp/internal-test
cc -O2 -Wall -Wextra tests/simulate.c Sources/Solver.c -lm -o /tmp/sim && /tmp/sim 3 5000
```

同じ内容を GitHub Actions (`.github/workflows/tests.yml`) で実行しています。
`Engine.m` / `Controller.m` は iOS SDK と実機が要るため、CI ではビルドしていません。

## ドキュメント

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 仕組み (ゲーム側の構造、探索、スレッド、状態)
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 表示の意味と症状別の対処
- [HISTORY.md](HISTORY.md) — 開発の経緯 (解析、却下した案、実機での確認)
- [AGENTS.md](AGENTS.md) — このリポジトリで作業する AI 向けの指示書

## 姉妹プロジェクト

- [LCAC-A](https://github.com/mar1mo-41414/LCAC-A) — パズルゲーム Arrows の自動クリア tweak。UI と IL2CPP の扱いはこれを参考にしています。
- [LCAB](https://github.com/mar1mo-41414/LCAB) — LiveContainer 用の広告ブロック dylib。

## ライセンス

このリポジトリのコードは [MIT License](LICENSE) です。
ゲーム本体や第三者のソフトウェアには、それぞれの権利・ライセンスが適用されます。
