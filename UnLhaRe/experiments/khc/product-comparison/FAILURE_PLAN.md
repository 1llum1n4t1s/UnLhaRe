# product-comparison failure-first

新helper/exampleと本run.ps1だけを追加し、既存product block/実験source/report/corpus/toolを変更しない。親だけがshared Cargoのhelper compileと比較nativeを実行する。

| 故障モデル | 実行前に固定する観測／分類 |
| --- | --- |
| binary pipe deadlock/上限 | stdout/stderrを同時非同期read、stdin非同期write、60s deadline。stdout1MiB+4096/stderr16KiB超過はkillし記録、一般errorを性能値へ換算しない |
| xz stdin/stdout未対応 | tiny実dataでa -txz -si -so / e -txz -si -soの直接byte往復を先行し、未対応は能力不足reportで静止。別条件へ変更しない |
| 条件不公平 | block1MiB以下、single-thread。KHC paid/low、Zstd -T1 -3/-19、LZMA2 -mx9 -mmt1 -md4m matched / -md8m rate-priority。md64mは事前予算外で起動0 |
| 非再現／CPU汚染 | warmup1+測定9、各round順序を反転。15%以下CPU quietを各round前にbounded確認。全sampleのsize/time/WS/private polling/byte比較を保存 |
| 容量／RAM／時間 | 各child WS/private polled peak160MiB、超過で当該候補中断。全suite30分。専用output8MiB、free5GiB+予算、report256KiB。raw/frame disk保存0 |
| 学習／holdout混同 | synthetic空/1B/repeat4KiB/random64KiB/正規UTF8日本語JSON4KiB、公開固定test key/IVのAES-CBC NoPadding64KiB、RAM Zstd3 repeat4KiB frame。Canterbury alice29/kennedy先頭1MiBはdevelopment、Silesia4件先頭256KiBのみholdout_window。全input SHA/window/source SHA/役割を記録。乱数を暗号化と呼ばない |
| 過大性能主張 | 暖機/測定/能力probeを別計数、非実行/資源超過/失敗/成功を分ける。CRC/全byteは実復号からrunnerが直接比較。再実行結果を握り潰さない |

Zstd -19は親確認に従いmemory_estimate_unavailableとして未実行（条件低下なし）。候補を勝手にmd64mなどへ変更しない。scriptはhelper指定と既存tools pinsを使い、source/input/toolの読取りlockと前後SHA/mtime/bytesを検査する。PowerShell7/.NET Process RAM binaryのみ。stdoutは要約、report.json以外の生成なし。既存出力先は拒否し上書きしない。OSポーリングはkernel PeakWorkingSet64/PeakPagedMemorySize64とPrivateMemorySize64を利用し、短命childの終了直前peakを完全保証せず観測回数/間隔を保存する。

worker compile/native/Git/削除/download/外部/version/追加委任0。apply_patchとnonwriting Rustfmt/PowerShell ASTだけ。実測性能・上限遵守・pipeline能力は親実行まで未検証。完了は3files READY/edit STOP。

親の追補契約：Attempt initial（元専用先）/repair1/repair2（別suffix）を固定し既存先は上書きしない。PreflightOnlyは出力directory/reportを作らず、helper未compile時はhelper pinを延期し、source/tool/input identityとrunner ASTのみ確認してnative0/write0。製品src/khc全Rust、指定lib/I/O modules、Cargo manifest/lock/configと実toolchain rustc/cargo実体をread lock＋SHA/mtime/bytes pinする。compiled provenanceそのものは親の別ledgerでありpreflight成功だけでcompiler実行を主張しない。

親の実行前定義：matched/ablation候補の実child ceilingをWS/private64MiB・60秒へ統一し、rate-priority LZMA2_8mだけ160MiBまでとする。実消費memory/timeが同じと偽って主張しない。結果から同じ制約下のParetoと率優先枠を分ける。前記160MiBは全childの外側最大で、64MiB群にはより厳しい値を実guardへ渡す。
