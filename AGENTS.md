# AGENTS.md — このリポジトリで作業する AI への指示書

このリポジトリは、[LiveContainer](https://github.com/LiveContainer/LiveContainer) 上で動く **2048** (`com.ketchapp.2048`) を
自動操作する tweak (dylib) の公開リポジトリです。
作業を始める前にこの文書を最後まで読み、利用者向けの説明は [README.md](README.md) / [README-EN.md](README-EN.md)、
仕組みは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、症状別の対処は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照してください。

> この文書と `docs/` が食い違ったら `docs/` の新しい記述を信じ、この文書を直してください。
> 秘密の値 (認証情報、証明書、署名情報) はコード・文書・コミット・ログのどこにも書かないこと。

---

## 1. 対象とゴール

| 項目 | 内容 |
| --- | --- |
| 目的 | 2048 の通常ゲーム (4×4) を自動で指す。2048 の到達は保証しない |
| 対象アプリ | 2048 **4.0.8** (`com.ketchapp.2048`)、Unity / IL2CPP |
| 実行環境 | LiveContainer (脱獄不要)。tweak フォルダに dylib を置いて使う |
| 成果物 | **Releases のアセットのみ** (リポジトリにバイナリを置かない)。`vX.X` タグを push すると Actions がビルドして添付する |
| ビルド | [Theos](https://theos.dev) (`make FINALPACKAGE=1`) |
| テスト | ホストの C コンパイラだけで動く (`make test` / `make simulate`)。CI は `.github/workflows/tests.yml` |
| 含めないもの | ゲーム本体・IPA・抽出データ (metadata / UnityFramework)・セーブ・スクリーンショット・ログ |

実機確認は**作者の端末 1 台**でしか行っていません。動作を変えたら、何を確認して何が未確認かを必ず文書に書いてください。

## 2. 絶対に守ること

- **ゲームのファイルを入れない。** IPA、`global-metadata.dat`、`UnityFramework`、抽出したアセット、セーブデータ、
  それらのスクリーンショットを追加しない (`.gitignore` でも除外している)。
- **秘密情報を書かない。** 証明書、プロビジョニング、Apple ID、署名用のパスワードなど。
- **バイナリをコミットしない。** `*.dylib` は `.gitignore` 済み。配布は Releases のアセットだけで行い、
  リポジトリに dylib を置かない (タグを打てば CI がビルドして添付する)。
- **実機で確認していない挙動を「確認済み」と書かない。** 未確認なら「未確認」と明記する。
- **測っていない数字を書かない。** 到達率・速度・成功率は、測った条件と試行回数と一緒に書く。
- ゲームの解析結果 (クラス名・メソッド名) は、実際に IL2CPP ダンプで確認したものだけを書く。

## 3. 構成

```
Sources/Controller.m   AUTO ボタン、CADisplayLink のループ、速度設定、状態表示
Sources/Engine.m       IL2CPP のシンボル解決、盤面の読み取り、HandleSwipe の呼び出し
Sources/Solver.c       移動・合体のシミュレーションと expectimax 探索 (ゲーム非依存の純 C)
Sources/*.h            上記の公開インターフェース
tests/solver_test.c    小さな盤面での移動・探索の確認
tests/internal_test.c  Solver.c を include して 10,000 盤面を move_rank と比較
tests/simulate.c       2 / 4 の出現を 90 / 10 と仮定した簡易シミュレーション
docs/ARCHITECTURE.md   仕組み
docs/TROUBLESHOOTING.md 状態表示の一覧と症状別の対処 (利用者向け)
HISTORY.md             開発の経緯 (新しい順)
Makefile               Theos ビルド + `test` / `simulate`
```

## 4. ビルドとテスト

```bash
make test        # 単体テスト + 10,000 盤面の移動処理比較 (Theos 不要)
make simulate    # 簡易シミュレーション。既定は 3 ゲーム × 5,000 手で数分
make SIM_GAMES=1 SIM_MOVES=1000 simulate   # 短く回す
make FINALPACKAGE=1                        # Theos が必要。.theos/obj/ に dylib
```

- `THEOS` が未設定でも `make test` / `make simulate` は動く。`make` (ビルド) は Theos が要る。
- ソルバーを変えたら、**テストが通ること**に加えて、シミュレーションの `max=` と `moves=` が
  意図したとおりに変わったかを見る (探索の乱数は盤面ハッシュ由来で決定的)。
- `Engine.m` / `Controller.m` は iOS SDK と実機が必要で、CI ではビルドしない。触ったら実機で確認する。

## 5. コードの方針

- **フックしない。** JIT・インラインフック・ゲームバイナリの書き換えは使わない。IL2CPP の API は `dlsym` で解決する。
- **IL2CPP オブジェクトはメインスレッドだけで触る。** バックグラウンドに渡すのは `int32_t board[16]` のコピーだけ。
- **盤面を直接書き換えない。** 方向を決めてゲームの `HandleSwipe` に渡す。
- **結果を適用する前に読み直す。** ゲーム・盤面インスタンス、状態、アニメーション、16 マスを再確認し、
  変わっていれば `STALE` を返して操作しない。無効化は `epoch` で行う。
- **状態文字列は UI に出る公開文字列。** 追加・変更したら `docs/TROUBLESHOOTING.md` の一覧も直す。
  `END` / `ERR` / `DATA` / `SIZE` は自動停止、という扱いを崩さない。
- 書式は既存に合わせる (4 スペースインデント、K&R ブレース、1 行 1 文)。1 行に複文を詰めない。
- `Solver.c` はゲーム側に依存させない。ホストでテストできる状態を保つ。

## 6. ドキュメントの書き方

このリポジトリの文書は次の役割で分けています。**同じ内容を 2 か所に書かないこと。**

| ファイル | 読者 | 書くこと |
| --- | --- | --- |
| `README.md` | 利用者 (日本語) | 何をするものか、動作確認状況、ダウンロード、使い方、注意、ビルド、テスト、ドキュメントへのリンク |
| `README-EN.md` | 利用者 (英語) | `README.md` と同じ構成・同じ内容。片方だけ直さない |
| `docs/ARCHITECTURE.md` | 開発者 | 仕組み、ゲーム側の構造、探索、スレッド、検証方法、既知の制限 |
| `docs/TROUBLESHOOTING.md` | 利用者 | 状態表示の一覧 (唯一の出典)、症状別の対処、Issue に書くこと |
| `HISTORY.md` | 開発者 | 日付ごとの経緯・解析結果・却下した案・実機での確認。新しい順 |
| `AGENTS.md` | AI | 方針、禁止事項、検証手順、落とし穴 |

- README は「結論 → 使い方 → 注意」の順。長い経緯は README に書かず `HISTORY.md` に置く。
- 日英の README は見出しの順序を揃える。英語版から日本語の `docs/` へリンクするときは「Japanese」と明記する。
- 事実と推測を混ぜない。「〜と思われる」は書かない。確認できていないことは「未確認」と書く。
- 表を使って、対応 / 非対応、状態 / 意味、症状 / 対処を 1 行 1 項目で書く。

## 7. 変更時のチェックリスト

1. `make test` が通る (ソルバーを触ったら `make simulate` も)
2. 状態文字列を足した / 消した → `docs/TROUBLESHOOTING.md` と `docs/ARCHITECTURE.md` を更新
3. 対応バージョンや対応モードが変わった → `README.md` / `README-EN.md` の「動作確認状況」を更新
4. 実機で確認した → `HISTORY.md` に日付・端末・結果を追記 (未確認ならそう書く)
5. ゲーム本体・抽出データ・セーブ・バイナリ・秘密情報を追加していない (`git status` で確認)
6. `README.md` と `README-EN.md` の内容がずれていない
7. リリースする場合は `HISTORY.md` を更新してから `vX.X` タグを打つ (ビルドと添付は CI が行う。下記)

## 8. リリース

タグを push するだけで、ビルドと Release 作成まで CI が行います。**バイナリをコミットしないでください。**

- タグは **`vX.X`** (必要なら `vX.X.X`)。例: `v3.1`
- `HISTORY.md` を更新して main にマージしてから、タグを打って push する。

  ```bash
  git tag v3.1
  git push origin v3.1
  ```

- `.github/workflows/release.yml` が macOS ランナーで Theos を用意し、`make test` → `make FINALPACKAGE=1` を実行する。
  ビルドされた `.theos/obj/**/Auto2048.dylib` をアセットとして Release を作成し、本文に SHA-256 を追記する。
  リリースノートはそのタグまでのコミットから自動生成される (`--generate-notes`)。補足は作成後に本文を編集する。
- タグ名が形式に合わないとワークフローは失敗し、Release は作られない。既存の `v3` は形式が違うため対象外 (作成済み)。
- **ビルドが失敗したら Release は作られない。** Actions のログを見て直し、タグを打ち直す:

  ```bash
  git tag -d v3.1 && git push origin :v3.1   # 失敗したタグを消す
  ```

- どうしても CI でビルドできないときの応急処置 (手元に Theos がある場合):

  ```bash
  make FINALPACKAGE=1
  gh release upload v3.1 .theos/obj/arm64/Auto2048.dylib   # 実際のパスは find で確認
  ```

- リリース本文には、対応するゲームのバージョン (現在は 2048 4.0.8) と実機で確認したことを書く。
  未確認のことは「未確認」と明記する。
