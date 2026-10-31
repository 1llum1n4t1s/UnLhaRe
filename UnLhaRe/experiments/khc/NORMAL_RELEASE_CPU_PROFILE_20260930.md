# 現行Releaseの実callstack帰属 — 2026-09-30

現行BT5/Beam/Blended/W2/B8192/64 MiB/Rangeを、debug infoだけ追加したRelease EXEとmatching PDBで採取した。旧9/29 ETLを新PDBで再解釈していない。**仕事の所在を示す診断であり、性能gate通過や7-Zip超過ではない。** 製品codec・parser・設定・wire・依存・versionは変更していない。

## 実体と検証

生成物基点は `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-current-release-cpu-20260930/`。

| 対象 | SHA-256 / identity |
| --- | --- |
| fixed group（2,811,006 bytes、11 entry） | `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76` |
| `bin/khc_lab.exe` | `804AA9095F209E932B4CE27F71188CA0BCAA1EE0156B4A5930212CF17697B6C8` |
| `bin/khc_lab.pdb` | `7A88BB6AE14D999301842246E93F97253CA5BAE4C900BB21F6A3CA9109DD11B2` |
| native MSF7 PDB GUID / age | `8671b4ab-e847-4086-8333-635f5416268e / 56` |
| 3 encodeの各483,130-byte frame | `CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D` |
| `capture-elevated/cpu.etl`（142,606,336 bytes） | `554F4864CA9D96FEF0B26D871EB45424F74BE1ADB740F16162C2D2A42A82526A` |
| `capture-elevated/report.json` | `B5C13EB644C2B16BD554B3F376E8966E47E7B64F63EA54C6E1F9FD025EBE7FCF` |
| `analysis-lifetime-fixed/report.json` | `BFF1473C4DCEFDEF91D709482AAA0E4D0E62497B68DECD11E47F0E2B146805AA` |
| `analyzer-e2e/report.json` | `19578D81C48A57F5946F6BFA2D7A9D0411F7758DB02E9240BDCC3D484641F505` |

環境はAMD Ryzen 5 7640HS、Windows build 26300、PowerShell 7.6.5、Rust 1.98.1、LLVM 23.0.0git、TraceEvent 3.2.6。詳細と30 source/Cargo inputsを含む前後hashはcapture reportへ保存した。buildはdebug-info-only設定。

```powershell
C:/Users/IMT/.cargo/bin/cargo.exe +1.98.1 rustc --locked --offline --release --target x86_64-pc-windows-msvc --example khc_lab -- -C debuginfo=2
```

通常runnerは非管理者tokenで、最初のWPR開始が `0xc5585011` により失敗した。録画未開始なので他sessionをstop/cancelしていない。既存録画なしを再確認後、`Start-Process -Verb RunAs -WindowStyle Hidden`でcapture harnessを実行し、今回所有の録画を開始・停止した。OS security policyは変更していない。最後のWPR statusは録画なしだった。

通常group-bench E2E、3回のgroup-encode、generic decodeにより、frame決定性・復元group SHA・全11 entryの名前/長さ/本文SHAを照合した。`group-decode`はmetadataを除くので全group SHA検査には使っていない。採取中のprocess CPU/wall時間は診断負担を含み、時間gateや7-Zip比較には使わない。

## 実stackの対応

生ETLのCPU `(PID,TID,TimeStampQPC)` とStackWalk `(PID,TID,EventTimeStampQPC)` を結合する。primitive値をcopyしcallback順には依存しない。ETLX・DIA・NGENPDB・online symbolsは使わない。

| 項目 | 実測 |
| --- | ---: |
| CPU sample / unique key / 対応stack | 3,199 / 3,199 / 3,199 |
| PID 27392 / 1580 / 9924のsamples | 1,088 / 1,057 / 1,054 |
| module内sampled IP / 未解決IP | 2,915 / 0 |
| kernel＋user split samples | 120 |
| 全対象StackWalk events / keys | 4,153 / 3,746 |
| CPUに対応しないkeys（除外） | 547 |
| missing / duplicate / compressed refs / lost | 0 / 0 / 0 / 0 |
| 結合後最大physical frames | 54 |
| runtime包含関数 / 未解決module frames | 344 / 0 |

各PIDにProcessStart/Stop各1回、module fullpathはfrozen EXEと一致。全sample UTCはcapture窓内で、小数秒を維持して照合した。ProcessStop直後のkernel teardown sampleも実行窓内なので除外しない。module外8,196 framesはKHCへ割り当てない。module return frames 26,962件はRVA−1、各chain先頭の捕捉IP 2,946件は減算せず解決した。

独立読み取り役はraw UTC/QPC・lifetime・fullpath、全physical frames、344関数のsample内dedup、inline-only排他合計2,915、provenanceを照合し不整合0を確認した。同一PID内の同base再ロードまで扱う汎用長時間trace analyzerではないが、今回のraw traceにその事象はない。

## 帰属と判断

以下は全3,199 samplesを分母とする**runtime包含率**。関数とinline childは重複するため足さない。

| 関数 | samples | 全sample比 |
| --- | ---: | ---: |
| `beam_plan_bt4` | 3,008 | 94.03% |
| `beam_plan_bt4_active` | 1,791 | 55.99% |
| BT `prepare_rest` | 972 | 30.38% |
| BT `insert_const` | 827 | 25.85% |
| `RepLengthCache<8>::length` | 347 | 10.85% |
| `push_match_edge_active` | 333 | 10.41% |
| `rep_length_limited` | 328 | 10.25% |
| `push_rep_edges_active` | 287 | 8.97% |
| `insert_lazy_width2` | 225 | 7.03% |
| `rep_sparse_boundary_lengths` | 156 | 4.88% |
| `advance_state` | 142 | 4.44% |

inline-only leaf/chain帰属は別項目に維持した。BeamActiveはinline-only 1,078に対しruntime包含1,791。両者を独立phase時間として足さない。BT leaf `0x6131A` / `0x613B1`はphysical callers `0xC760B → 0x9A8DA → 0x1F5B19`につながり、最後は `khc_lab.rs:3973`の通常GroupEncode入口である。`hybrid_splice_screen` / `ptt5_transpose_screen` closure名だけでscreen実行とは判断しない。generic/最適化symbol identityの正確なfolding原因は未確認。

独立source調査で `lz.rs:3475`のRep子状態を初回cost通過時だけ生成する未評価の同値仮説を見つけた。既存cost棄却は生成closureを呼ばず、`advance_state`はRep長に依存しないので、全長候補棄却の親/indexだけ配列回転を省ける。ただし全`advance_state`でも4.44%の参考規模にすぎず、一部の省略で必要な37–43%短縮は説明できない。既往のindex別回転やMatch状態hoistとは異なるが、**固定gateへ届く構造候補として実装しない**。profile比率は統計的な厳密上限や高速化の保証ではない。

固定dev条件483,599 bytes / encode strict `<574.5624 ms`、同thread/memory上限、decode、カテゴリ・native-solid・未使用holdoutを含む総合目標は維持する。今回、新しい性能候補・計時・holdoutは作っていない。

## 再現とCLI拒否E2E

`sample-current-release.ps1`は絶対pathのBinaryPath/PdbPath/GroupPath/RustcPathと新規WorkDirectoryを要求する。matching pairを先に固定し、管理者実行時も既存WPR録画を止めない。

採取済みETLの解析とCLI拒否検証は、上記生成物基点を `$profileRoot` として実行する（出力先は新しい名前にする）。

```powershell
./experiments/khc/analyze-current-cpu.ps1 -CaptureReportPath "$profileRoot/capture-elevated/report.json" -BinaryPath "$profileRoot/bin/khc_lab.exe" -PdbPath "$profileRoot/bin/khc_lab.pdb" -WorkDirectory "$profileRoot/analysis-new"
./experiments/khc/verify-current-cpu.ps1 -CaptureReportPath "$profileRoot/capture-elevated/report.json" -AnalysisReportPath "$profileRoot/analysis-new/report.json" -WorkDirectory "$profileRoot/analyzer-e2e-new"
```

E2Eは実ETLの正常report/source一致と、既存work no-clobber、未検証capture、EXE hash不一致、ETL hash不一致、PID重複、無効時間窓の6負例を計7 checksで確認した。全childは期待した理由でexit非0。入力・EXE/PDB/ETL/source・既存reportの前後SHAは不変。compressed/lost/stack欠損の拒否はsource確認のみで、実ETL負例のE2E確認済みとはしない。

途中の数値format失敗とDateTime文字列化の小数秒消失は修正済み。失敗reportを成功として使用していない。raw ETL・matching pair・最終analysis・E2E reportは再確認可能な証拠として保持。使用済み過程reportはpath/hash/結論をDEVELOPMENTへ残してから、今回所有の絶対pathだけを確認して清掃する。
