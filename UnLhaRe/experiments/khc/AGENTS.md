# 高圧縮実験の容量制約

- 新しいWindows実験では安全なslugを `$env:KHC_STORAGE_TASK_ID` に必ず指定する。作業先は検証済みの `%TEMP%\UnLhaRe\work\<task-id>`、保持証拠は `%TEMP%\UnLhaRe\TaskArtifacts\<task-id>` に限定する。`%TEMP%` はユーザー環境変数TEMP（`[Environment]::GetEnvironmentVariable('TEMP','User')`）で、wrapperが子プロセス向けに差し替える `$env:TEMP` ではない。Cドライブ上でもよい。既存の親階層を含めreparse pointを拒否し、基点ドライブが利用不能なら停止する。
- 比較は `run-storage-experiment.ps1`、Cargoは `run-serial-cargo.ps1` を通す。Cargoのtarget-dirとbuild-dirは同じタスク作業先の `cargo` に固定し、単体rustc・子プロセスのTEMP/TMP・ログ・検証出力もタスク作業先へ置く。リポジトリの `build/cargo` へ新しい出力を作らない。
- 容量・清掃の正本は [STORAGE.md](STORAGE.md)。旧build・旧CドライブのTemp/保全・全タスク作業先/保全先を除外せず合算し、Cargoや固定保管ZIPの内数を二重計上しない。登録runnerの開始前・実行中・終了後チェックを通し、空き5GiBに加えて実験予算を確保する。これは走査とsamplingであり、プロセスの書込みを強制制限する機構ではない。
- 新しい生成処理は出力前に件数×レコード長などの上限を計算し、予算を越える生データを作らない。超過が判明したら重複起動・無制限再試行をせず、出力方式を見直す。例外の予算拡大は理由と見積りを先に報告する。
- 大量の数値列・トレースは逐次比較とダイジェスト、件数、上限付きの失敗証拠で検証する。native/portableの同一生出力を重複して常時保存しない。ただし比較を実行せずハッシュだけで正当性を主張しない。
- 固定corpus・7-Zip基準・候補実行ファイル・採用結果・最小再現入力・ソース/コンパイラ/設定の識別値を保持する。既存の固定契約やSHA参照は書き換えず、参照された証拠を勝手に消さない。
  - 例外（2026-11-12、本人承認）: 旧Dドライブ作業フォルダー廃止に伴うパス置換で変わった `candidate-e2e-recovery` 一式と3つのscreen scriptのSHA固定値だけを、変更後の値へ連鎖的に更新した。
  - 例外（2026-11-13、本人承認）: 製品形式をKHCからLHC（LHA High Compression）へmagicを含めて改名した。ビルドを保つため、実験Rustコードの `src/khc` パスと `unlhare::khc` / `crate::khc` 参照だけを `lhc` へ置換した。このディレクトリ名、記録文書、PowerShell/Pythonスクリプト、研究frameのmagic、SHA固定値は旧称のまま残す。固定SHAと照合する旧スクリプトや旧 `khc-*` CLI・`--example khc_*` を呼ぶスクリプトは、再実行前に現行名へ合わせた新しい契約が必要。
- 旧 `build/`・CドライブのTemp/保全は読取専用の履歴入力として扱う。旧 `cleanup-incremental.ps1` の直接実行は通常経路に戻さず、新しいrunの清掃は [STORAGE.md](STORAGE.md) のPrunlet段階手順を通す。復元ZIP・台帳・削除記録はタスク保持先へ置き、既存の証拠や固定SHA参照を変更しない。
- 清掃後の再ビルドはキャッシュを必要分だけ再生成する。製品ビルドや検証を容量節約のために省略した場合は、未実行と明記する。
