# 容量整理と今後の実験予算（2026-10-02 JST）

## 実測結果

- 対象は新版 `UnLhaRe/build` のCargo増分キャッシュのみ。`cargo` / `cargo-*` のdebug/release直下およびtarget triple配下の `incremental` を79ディレクトリ、28,810ファイル削除した。
- 削除対象の論理ファイル長は7,521,775,771 bytes（7.005GiB）。Cドライブの実測空きは3.770→10.005GiB（約6.235GiB増）。論理ファイル長とドライブ空きの差は割当容量や同時変動を分離計測していないため、実際の回収量として7.005GiBとは主張しない。
- 全対象について、絶対パス・親要素/配下のreparse拒否・Git追跡なし・Cargo標識・対象外拡張子なし・使用中プロセスなしを確認してから同一PowerShellで削除した。削除後の残存は0、続くdry-runも対象0。
- 依存ライブラリ、実行ファイル、PDB、製品artifacts、固定corpus、比較結果は対象外。`build/cargo/release/deps` には再生成入口が固定SHA参照するrlib/DLLがあるため保持した。
- 同depsの全745ファイル、Q16/causal候補直下の全143ファイル、固定group・7-Zip・共用khc_labの3ファイル、計891ファイルの削除前後SHA-256を照合し、一致した。
- 共有キャッシュ、他リポジトリ、UnLha32Reは操作していない。削除済み増分キャッシュは必要時にCargoが再生成可能。ソースや成果物を削除していない。

## 再実行と証拠

```powershell
# 既定は表示のみ。稼働中のビルド・検証があれば拒否する。
./experiments/khc/cleanup-incremental.ps1
# 削除が必要な場合のみ指定する。
./experiments/khc/cleanup-incremental.ps1 -Apply
./experiments/khc/disk-budget.ps1 -WorkDirectory build/khc-q16-dense-cts-20261001
```

- 清掃台帳: `build/incremental-cleanup-20261001T153229108Z.json`
- 保存対象SHA・容量チェック検証: `build/incremental-cleanup-20261001T153229108Z-verification.json`
- 容量チェック正常系が成功し、範囲外・1MiBへの予算縮小・1024GiBの空き要求はそれぞれ失敗した。既存データを膨らませる異常fixtureは作っていない。
- 両スクリプトのPowerShell構文解析エラー0、`git diff --check` 成功。製品のビルド・機能テスト・速度試験は容量整理では実行していない。

## 継続方針と限界

新規実験は共用Cargo targetを再利用し、開始前・終了時の容量チェックを必須にする。既定で1実験256MiB、空き5GiB＋実験予算。生成処理にも事前件数計算・出力上限を持たせ、数値列は逐次比較・件数・ダイジェスト・小さな失敗証拠を優先する。

追加した `AGENTS.md` は今後の実験の作業規約で、既存の固定SHA契約を変更していない。容量チェックは事前・事後判定であり、OSのディスククォータでも既存全入口の自動ラッパーでもない。新しい実験の実行時に呼び出すこと。今回のチェック成功を将来の全処理の遵守実測と混同しない。

7-Zip超えの目標は未達成のまま。容量整理は圧縮率・速度改善の証明ではない。
