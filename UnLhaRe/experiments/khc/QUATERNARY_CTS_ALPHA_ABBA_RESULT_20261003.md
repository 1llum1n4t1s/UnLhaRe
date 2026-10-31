# depth5 CTS alpha共通係数: 単独候補の実行結果

## 結論と基点

PERF-ALPHAは数値・拒否優先・全状態・全frame/復元/Proof比較に合格したが、事前固定した圧縮と展開の両方向平均短縮を満たさず未採用。従来depth5旧pool/旧Math/旧updateを維持する。QCANCEL、Math-U64も未採用のまま混ぜていない。都合のよい数字を選ぶために候補を再実行しない。

固定size<=483599Bは全4frameで合格。正式single-thread codec median<574.5624ms、machine CPU<=15%、holdout/categories、4native、製品/API統合は未検証で、7-Zip総合超えは未達。本段階は開発Canterburyでのwarmupなし1周の診断であり正式gateの代用ではない。goalはactive。

## 再現証拠・一度の実行

- 主契約 `QUATERNARY_CTS_ALPHA_ABBA_CONTRACT_20261003.md`、9120B、SHAC1D25F68A4A8CEC4CC3A1291E4944121486B8B3DF456B1AE5E9D434B8D9B6DBA。
- 補足 `QUATERNARY_CTS_ALPHA_ALIAS_SUPPLEMENT_20261003.md`、SHAAC3A1B310D275885AF8BFAB2E2E19E9DE0368533A55AB470042F8EBFC880F69C。主契約を上書きせず旧独立oracleとSnapshot候補経路を是正した。
- report `build/khc-quaternary-cts-alpha-20261003/report.json`、362487B、SHA66CAFD4526241B1A13C83754FCE142F976344ECBC0E817405CCC68DFEA26E663。
- 同root `alpha-o2-yes.exe`、477696B、SHAA91E7044F5B611550F3C772BE9C52A5CA83128E2D2A6FCCBEC716CA5CEFAA70A。
- runner `quaternary-cts-alpha/verify-alpha.ps1`、84346B、SHA812971D5122F9171113C5E0C2942B43F0064EF6143825ADD734CAEE591CF2406。

rustc1.98.1(48a229cea 2026-09-01)、SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。専用PowerShell7.6.5、SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。Windows11Pro10.0.26300/x64、Ryzen5 7640HS/6core/12logical。edition2024、frame_audit/primitive_audit、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、/DEBUG:NONE。

workerは新8fileの所有を返却・編集停止した。親は新数値/E2E全文と40829文字のrunner差分を読み、独立したcts_alpha_code_auditの確認を回収し、parent nonExecute後にExecute1/compile1/CLI5だけ実行した。records17（Rustfmt stdout10/compiler version1/build1/CLI5）は全completed/exit0/errorなし。build3316.4862ms、未使用import警告3件（candidateと凍結depth/sealedのreexport）。候補CLI stderrは空、候補compile/CLI失敗・再実行なし。

FAILURE_PLAN.mdは4683B/SHAC2D55BCC8443A453CB7019E54F91BEE9B770426BD4B74DB4A5524748F08DE530。親が内容とidentityを確認したが、コードより先の保存順はworkerの報告で、親の独立した時系列監査とは区別する。初回nonExecuteのnew_cts=baseline構成ではSnapshot比較が候補を通らない欠落を親が発見し、補足を保存して実行前是正。主契約や旧sourceは改変していない。

親の読み取り集計は一度recordのexit/argvを別schemaのexit_code/argumentsと誤参照して失敗17件と誤算した。実fieldを確認して同じ保存reportを再集計し、実失敗0・build1・CLI5を確認した。候補の実行失敗や再実行ではない。

## 数値・拒否・状態・全出力

新alpha_kernelは旧update入口guardとdepth0空loopの意味を保ち、after依存denominator/alpha/retainedの旧checked式だけをloop外へ移した。after∈[1,CAP]で係数関連Errは到達不能。各段のweight/own/rawmass/after検査、u128 posterior・product/next、Err順は旧本文一致。新CTSはupdate reexport先以外に数値・seal・current guard・CAP・prepare全完了後commitの差がない。

| 追加比較 | 件数 |
| --- | ---: |
| kernel正常・全Result配列 | 540 |
| kernel入口拒否・Err | 225 |
| switch拒否・Err | 96 |
| 複合level拒否・優先Err | 8 |
| kernel合計 | 869 |
| depth0独立model組 | 24 |
| depth0成功observe / 拒否 | 120 / 144 |
| pure predict / 公開Snapshot全field | 120 / 312 |
| 旧新全state / 各拒否前後全state | 552 / 288 |

旧oracleは凍結reference_cts::update_kernelと凍結baseline depth modelであり、新alpha実装を共有していない。root new_ctsは候補、baseline_ctsは凍結独立module。oldcodecのuse aliasだけbaselineへ変更して数値/timer本文を保持、optimizedと凍結mid Snapshot比較は候補へ接続した。

- compare-snapshotはcandidateを通り、sealed392成功/223拒否/22 failed observation。depth[4,5,6,7,8]は成功30/拒否1070/failed90/pure5/constructor2/compact60に一致。
- 旧新各selfcheckはplain70/canonical70/malformed165/short20/model named70/assertions80/CAP5。stale/tamper/foreign/rebased、拒否優先、全state不変を保持。
- 全入力2811006Bを1read、4往復で全plainを11244024B直接比較。往復全Proof/stats4回、first Aとの全Proof/stats3回、全frame byte3回1436250Bが一致。14field ProofのCDFはto_bitsで比較し、hash-only/JSON丸めで代用していない。

全frame478750/header285/payload478465。CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052、grammar/count/classes、nodes1365/class・CTSnode196560Bは固定値に一致した。

## ABBA観測と未採用

| index | 実装 | encode ms | decode ms |
| --- | --- | ---: | ---: |
| 0 | old A | 6259.2134 | 6513.9272 |
| 1 | new B | 6595.1112 | 6189.9340 |
| 2 | new B | 6229.8772 | 5573.2074 |
| 3 | old A | 5939.3975 | 5731.6003 |
| A平均 | old | 6099.30545 | 6122.76375 |
| B平均 | new | 6412.49420 | 5881.57070 |

観測上encodeは約5.135%増加、decodeは約3.939%短縮。both_mean_directions_lower=falseのため未採用。warmup0、ABBA1、外部repeat0、inner timer0。配置・CPU scheduling・時間変動を分離していないので、統計的に確定した性能差とは言わない。別binary/別時期のQCANCEL/Math/旧depth値との比率を採用判定へ使わない。旧library codegenでの除算残存は事実だが、今回full codecの高速化保証にはならなかった。

## identity・容量・清掃

149 sources before/afterと親live SHA/bytes/UTCticks照合mismatch0、EXE before/after/live一致。compiled graph17unique/18edges/root13/unique destinations16、Snapshot candidate接続・本文・validator guard合格。旧136/130/118/106/99/89/84failed/72/60/48の全loop/EXE/失敗証拠を維持し、旧Executeを繰り返していない。現在149件の完全identityを保存した。

AlphaはEXE/report2件840183B（約0.801MiB）。QCANCEL/Math/codegen/Alphaを合わせた今回の実行生成物は8件2585523B（約2.466MiB）。小さなsource/契約/結果文書は別途保持し、入力/frame/plain/temp/bak/PDB/Cargo target/traceコピーは作っていない。各8MiB予算とEXE1MiB/report512KiBに収まる。終了時runner空き79485317120B、親再確認時78789644288B（約73.38GiB）。ドライブ全体の空き変動をこの作業の生成量や清掃と同一視しない。

reference frame最大1枚478750B、live current+reference最大2枚957500B、cloneなし、最終references0。全process/allocator peakとは区別する。所有codec process0、用途済み一時物なし、削除対象なし。再現証拠・固定入力を保持し、製品/API/wire/version/x86/shared cache/既存dirty changesを変更していない。

## 次段階と未達条件

opopに従い正しさ・コード生成・実時間を別判定し、3候補とも両方向短縮しないため基点へ採用しなかった。worker-high（gpt-6.1-sol/high）1名が8fileを所有、readonly analyst cts_alpha_audit/cts_alpha_code_audit（gpt-6.1-sol/medium）が静的成立性と独立コード確認を担当。親が補足・レビュー・Execute・採否を所有した。

次のアルゴリズム案は、CTS/pool重みをQ21、log/expを旧Q32・Q48 Mathのまま使う混合精度。posterior分子<=2^63、score積和<2^61等のu64/i64化余地がある。ただし単なる定数変更では合法KT入力のゼロ確率とalphaゼロが発生する。最低KT1予約、alpha最低1、全単位・丸め・学習順・改変入力契約、新magicを先に固定する必要がある。旧Q32との数値同値ではなく別研究形式で、圧縮率・速度・holdoutは未測定。10倍改善や7-Zip超えを保証しない。

正式median/CPU、holdout/categories、4native、製品/API統合、全process peakは未検証。本診断encodeは正式閾値より大幅に長く、総合目標は未達のまま継続する。
