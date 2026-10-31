# depth5 pool Math位置計算u64: 単独候補の実行結果

## 結論と固定条件

PERF-POOL-MATH-U64は旧新の数値・全frame・復元・拒否状態の直接比較に合格したが、事前条件の圧縮・展開両方向の平均短縮を満たさなかったため未採用。従来depth5の旧pool/旧Mathを比較基点として維持する。PERF-POOL-QCANCELも未採用のまま混ぜていない。好都合な数値を得るための再測定は行わない。

固定size<=483599B、正式single-thread codec median<574.5624ms、machine CPU<=15%、holdout/categories、4native、製品/API統合は維持する。本段階は開発Canterburyの単一ABBA診断であり、正式速度・CPU・holdout gateの合格ではない。7-Zip総合超えは未達、goalはactiveのまま。

## 再現証拠と実行境界

契約 `QUATERNARY_CTS_POOL_MATH_U64_CONTRACT_20261003.md` SHA89D92DDA332CFB57DB74322814BAC53306DC00E9EB9282B3C283182F44BD07FBを事前固定した。新scopeは `quaternary-cts-pool-math-u64/` の8件のみ。FAILURE_PLAN.md SHA192AB7A74D5A84959E6203685A889FC2766C751AAF19EBB4D54F33CB99E6E94Eの内容とidentityは親が確認した。コードより先の保存順はworkerの報告であり、親の独立した時系列監査とは区別する。

- report: `build/khc-quaternary-cts-pool-math-u64-20261003/report.json`、354054B、SHA0E252310BB8BE3415828258F190097D31CBD380A92A9CE9612C696E265E2D998。
- EXE: 同rootの `math-o2-yes.exe`、493568B、SHA60089C9B6241950CA9B29A1021AE85624C0BF1BD7C0F226F566CBD82033A960D。
- compiler: rustc1.98.1 (48a229cea 2026-09-01)、SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。
- runtime: 専用PowerShell7.6.5、SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。
- Windows11Pro10.0.26300/x64、Ryzen5 7640HS、6core/12logical。edition2024、frame_audit/primitive_audit、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、/DEBUG:NONE。

親レビュー後のExecute1・compile1・候補CLI5（compare-snapshot、selfcheck、selfcheck-new、compare-math、abba）で完了し、失敗・再実行なし。全records17はRustfmt stdout10、compiler version1、build1、CLI5。build exit0、候補CLI stderrは空。compileには凍結CTS未使用import2件と新poolのUpdate未使用1件の計3警告がある。workerのnonExecuteではpin移動時の旧path graph誤参照を検出して修正したが、guardを緩めていない。型検証・compile・候補CLIは親Executeの1回だけ。

## 数値・状態・全出力の一致

新Mathは旧Math全文から位置計算だけ5箇所をchecked u64へ置換した。ln position<2^43、exp mag<=2^55/position<2^60でexactに収まる。差分と余りの補間積、Q48 LUT、signed helpers、domain/Err/丸め/切捨ては従来どおり。新poolは旧predictのMath importだけ変更し、pの汎用u128正規化は保持した。型・observe・seal・CAP・prepare-all-before-commit・depth/model/E2Eを変更していない。

| Math比較 | 全件 | 正常 | Err |
| --- | ---: | ---: | ---: |
| ln_scaled | 291 | 188 | 103 |
| ln_count | 8 | 4 | 4 |
| exp_neg | 36958 | 36954 | 4 |
| method合計 | 37257 | 37146 | 111 |

ln入力はunique97、exp入力はunique36958。親の独立BigInteger fixture計算と件数一致。各Result値/Err文字列を旧新で直接比較した。L4097/E4097/counts32769の全40963entryをmethod群の前後に2回、計81926entry直接比較し、table不変も確認した。hash-only/digest-onlyを直接比較の代用にしていない。

- poolはprimary Prediction104と拒否後12の計116、Update257全fieldが一致。uniform/BigInt正負/rare q0とfactor・gradient0/next不変、12拒否のErr・優先順・拒否後全state一致を確認。
- compare-snapshotはsealed392成功/223拒否/22 failed observation。depth[4,5,6,7,8]は成功30/拒否1070/failed90/pure5/constructor2/compact60で凍結件数一致。
- 旧新それぞれのselfcheckはplain70/canonical70/malformed165/short20/model named70/assertions80/CAP5。改変・stale・foreign・rebased・CAP・拒否優先順・原子性を維持。
- 全入力2811006Bを1回読み、4回encode/decodeと全plain直接比較（計11244024B）。各往復全Proof/stats4回、first Aとの全Proof/stats3回、全frame byte比較3回（計1436250B）。Proof14fieldはCDF to_bitsも一致。

4frameとも478750B/header285/payload478465で固定size合格。CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052、固定grammar/count/classesも一致。nodes1365/class、CTSnode196560Bを保持した。

## ABBA観測と採否

| index | 実装 | encode ms | decode ms |
| --- | --- | ---: | ---: |
| 0 | old A | 5615.4071 | 5513.9288 |
| 1 | new B | 5761.8987 | 5746.5609 |
| 2 | new B | 5998.7194 | 5750.5635 |
| 3 | old A | 5915.3541 | 5887.5351 |
| A平均 | old | 5765.38060 | 5700.73195 |
| B平均 | new | 5880.30905 | 5748.56220 |

観測上encodeは約1.993%増加、decodeは約0.839%増加。warmup0・ABBA1周・外部repeat0・inner timer0の単発診断であり、統計的に確定した低速化とは主張しない。両方向ともB平均がA平均未満ではなく、both_mean_directions_lower=falseで未採用。実行時期・binaryの異なる過去候補との比率を採用判定へ使わない。

## identity・容量・清掃

reportの130 sources before/afterと親のlive SHA/bytes/UTCticks照合はmismatch0。EXE before/after/liveも一致。compiled graph17 unique sources/18edges/root13/unique destinations16。旧118/106/99/89/84/72/60/48の全loopとEXE/既存失敗証拠を照合し、旧Executeは繰り返していない。現在130件の完全identityを保持した。

生成物はEXE/report2件847622B（約0.808MiB）。QCANCELの821049Bとの合計1668671B（約1.59MiB）に収まり、input/frame/plain/temp/bak/PDB/Cargo target/traceのディスクコピーは生成していない。各候補8MiB・EXE1MiB・report512KiB・空き5GiBの事前/事後guardを通過。実行終了時空き81096339456B（約75.53GiB）。report.disk_afterは最終report書込み前の観測であり、最終bytesは親directory実測とrunner最終capacityで確認した。ドライブ全体の空き変動をこの作業の生成量と同一視しない。

reference frame最大1枚478750B、live current+reference最大2枚957500B、cloneなし、最終reference0。これはframe所有数の実測で、全process/allocator peakの計測とは区別する。終了時の所有codec process0、用途済み一時物なし。固定入力・source・実行証拠は保持し、製品/API/wire/version/x86/shared cache/既存dirty changesは変更していない。

## 次段階と未検証

次はPERF-ALPHAのafter依存係数の共通化が実際のコード生成でも未除去かを調べる。ソース上はdepth5の各枝5回を1回に減らす余地があるが、compilerが既にhoistする可能性があり、性能改善と決めつけない。今回の未採用2候補を連結せず、必要なら測定方法を先に固定して主要コストを確認する。新アルゴリズムや数値精度変更は本段階へ混ぜない。

opopに従い正しさと速度効果を別判定し、採用条件を満たさない候補を基点へ採用しなかった。worker-high1名（gpt-6.1-sol/high）が8fileを所有し、readonly analyst pool_next_math_audit/pool_math_code_audit（gpt-6.1-sol/medium）が算術と独立コード確認を担当。親が契約・最終レビュー・Execute・採否を所有した。外部資料照会・書込みなし。

正式median/CPU、holdout/categories、Windows/macOS x64/ARM64 native、製品/API統合、全process peakは未検証。本診断encodeも正式閾値より大幅に長く、7-Zip総合超えを達成したとは報告しない。
