# CRC付きanchor wire：全frame接続の実検証

親レビュー後に単一compile/native3を実行しexit0、diagnostic-passed。研究形式KHQCHA01へ32B metadataをheader CRCの範囲内に組み込み、正常/不正metadataと固定input全plainの復元を確認した。製品形式への採用ではない。総合GOALの速度/holdout/4native等は未達、activeを維持する。

| 固定pair | 旧hard-cut-model-lazy | 新anchored wire |
| --- | ---: | ---: |
| header / payload / frame B | 285 / 478571 / 478856 | 317 / 478571 / 478888 |
| 単回内部encode ms | 2511.0040 | 2610.0385 |
| 単回内部decode ms | 2487.2902 | 2299.3109 |

新研究frameはsize条件483599Bより4711B小さいが、完成公開書庫・正式速度の達成根拠ではない。control-first/warm0/CPU quiet未確認の一回比較で、encodeは99.0345ms増加、decodeは187.9793ms減少した。統計的な速度改善、旧単体inverseの割合の全処理への転用、7-Zip超えを主張しない。主処理を軽量化する工程が必要。

## 実行経路と検証

- 元normal14・malformed34のstrict原因・short4を維持。旧lf_cycleのみ新inverseのLF early primary cycleへ明記して変更。n7/8正常2、anchor named拒否10、same-process回復10、新magicを旧decoderへ渡す拒否1。anchor CRC bitflip、CRC修復済みrange/anchor0/duplicate/endpoint/n72早期primary、不足/余剰/fallback余剰を拒否した。
- 固定input一read、旧新各encode1/restore1、固定再encode0。全共通header/alphabet/payload bytes、全plain2811006B、各typedProof14、型間Debug14、許可4fields＋追加2fields以外の全statsを直接比較した。両frame全体の同一性は意図的に成立しない。
- 元SA-IS・新SA採取・anchor inverse・lazy model/math/poolを直接参照。codec20/E2E5/scope0の全文復元残差0。source closure24files/24edges/165961B、188 unique pins。製品dirty20files/旧証拠は変更なし。
- 各nativeのWS/private peaks Bは旧self15482880/12681216、新self15228928/12611584、fixed pair55480320/52011008。全て160MiB以内。BWTのsource保持推定142651883Bは実peakそのものではない。
- compile1/native3の全child exit0。親独立readonlyは213 before/after/live組（重複を含むsource24+pins188+EXE1）、raw JSON3全文一致、厳密理由/全stats/Proof/生成物2files/owned process0を確認。追加compile/native0。

## 成果物と再現

build/khc-anchored-wire-20261004 はEXE543232B＋report167627B＝710859Bのみ。新Cargo/PDB/ASM/input/frame/plain/rawtraceコピー0、削除0。検証終了時free43666116608B（約40.7GiB）。共有ドライブの減少を今回の約694KiB出力へ帰属させない。

| 証拠 | SHA256 |
| --- | --- |
| report.json | D580A0C79163CB6E7847E6FDC8663CC0C613AE84906A032038BEC9377CD2074F |
| anchored-wire-o3.exe | B46EA3ED817AC39E9B4E42838D06CB594045B82293E7993DBC6E2DED3C8377B3 |
| run-native.ps1 | 05ADEF732BD75D4DC04C1DF5414F57B5B2A698B67FF5B3817E12B6A790845E55 |
| verify-artifacts.ps1 | 3E5BBCD809F5EE33999F864CEA96FAD7E8C01B0D7DFAD99C031DD084C160D77D |

既存成果物の確認入口は anchored-wire/verify-artifacts.ps1。run-native.ps1は未使用outputを要求し、既存成果物を上書き再実行しない。固定runtime1.98.1/edition2024/wire_audit/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE。nativeはWindows x64だけで、fullCLI/warm1+9/quiet/holdout/API/4nativeは未検証。

次の構造候補は固定65536-run/14tile/Dense1reuseの無料情報診断。独立調査・先行PLAN・failure-first実装5filesまで保存済み、compile/native0。paid metadataや実frameの採用と混同せず、固定全GOALを維持する。
