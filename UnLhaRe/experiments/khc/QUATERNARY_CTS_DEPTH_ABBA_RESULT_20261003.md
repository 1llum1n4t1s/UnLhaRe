# CTS depth8/5: 同一binary ABBA結果

## 結論・採否

progress。固定[8,5,5,8]のABBA1周はpassed。各encode/decode2回の平均でdepth5が両方向とも短かったため、次の性能研究の基点としてdepth5を暫定選択する。製品既定値/API/version/formatの変更・製品最終採用ではない。frame478750Bは固定size<=483599Bを満たす。

同じbinary・同じCLIの診断平均はencode6915.2738ms→5518.28185ms（20.20154213%短縮）、decode6769.0944ms→5457.50235ms（19.37618199%短縮）。warmup0/1周/各2sampleであり、正式中央値・統計的優位・他時点との改善率ではない。旧KT/sealedの改善率を足したり掛けたりしない。正式速度<574.5624ms/CPU<=15%、holdout/categories、4native、製品/API統合は未検証。7-Zip総合超え全goalは未達。

## 観測値

| index | depth | frame B | node Vec B | encode ms | decode ms | 全plain比較 B | 再出現frame比較 B |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 8 | 474734 | 12582864 | 6960.2907 | 6788.2281 | 2811006 | 0 |
| 1 | 5 | 478750 | 196560 | 5549.7364 | 5352.2487 | 2811006 | 0 |
| 2 | 5 | 478750 | 196560 | 5486.8273 | 5562.7560 | 2811006 | 478750 |
| 3 | 8 | 474734 | 12582864 | 6870.2569 | 6749.9607 | 2811006 | 474734 |

各回の全plain、encode/decodeの全Proof・stats・CDF bitsが直接一致。再出現2frameは計953484Bを全byte直接比較して一致。A各2回は旧frame fields24Bとmetadata/payload474694Bも直接一致。Bのsize・payload/headerCRC・base/CDFはmidの固定値を維持し、frameの同一性をdigestだけで主張していない。

各depthのnode Vec量はCTS領域だけで全process peakではない。depth5は約1/64のnode領域となり、frameはdepth8より4016B増えるが上限まで4849Bの余裕を保つ。call timerは既存codec内、比較・保持・JSON整形・dropは計時外。

## 実行・正しさ

契約SHA5617F19FE3D9325E6D7737FB898A218F8350926AE521D751A1E370FAD7CAAABE。UTC2026-10-03T09:11:25.0472751Zから09:12:29.1355390Zまで。親Execute1回・compile1回・compare-snapshot1/selfcheck1/ABBA1。rustc1.98.1/edition2024/frame_audit/primitive_audit/opt2/overflow yes/panic abort/debug0/DEBUG:NONE、同一EXE、child120秒/stdout stderr各64KiB。compile exit0/2083.7115ms、compare exit0/2181.3591ms、selfcheck exit0/4084.3037ms、ABBA exit0/49445.1229ms。実行CLIのstderrはすべて空。ABBA child processor48906.25msはmachine CPU15%の観測・証明ではない。

sealed pair392成功/223拒否/22failed predict、digest4ed027cbcaf271d4。独立depth[4,5,6,7,8]はsuccess30/refusal1070/failed90/pure5、constructor拒否2/compact60。selfcheckはnormal/plain/canonical各70、malformed165、short20、model named70/assertions80、CAP exact5。CRC depth被覆、foreign/rebased、CAP、current guard priority、unused zero、pure prediction、拒否前後の全stateと全prepare後commitを維持。

ABBA encode/decode/plain比較/stats比較各4、input/baseline attempt・success各1、size合格4、protocol再出現2、repeat比較attempt・success各2、warmup0、cycles1、追加repeat0、inner timer0、全入力canonical再encode0。compile警告は凍結reexportのunused importsで、警告除去のために旧sourceを書き換えていない。失敗時のAccounting経路は静的に確認し、故障注入CLIは別に実行していない。

source106のbefore/after/live SHA/bytes/UTCmtimeを親も照合し相違0。compiled13sources/12edges/root10/unique12。旧basis48/KT64 60/sealed72/failed84/depth89/mid99とEXEはpassed、旧Execute・旧EXE再測定なし。EXE before/after/live不変、専有候補process終了時0。git diff --check passed（既存DESIGN.mdのLF/CRLF warningのみ）。depth4出力rootを親が再読し、7file/2332061Bと専有候補process0も確認した。

## RAM・容量・保持

referenceは最大2枚953484B、current candidateを加えたframe bufferはindex2で最大3枚1432234B。各回のlive framesは[1,2,3,2]、bytes[474734,953484,1432234,949468]。保持後referenceは[1,2,1,0]枚、bytes[474734,953484,474734,0]。B比較後にold/current Bを即dropし、最後にAもdrop。frame cloneなし。旧baseline474730Bとinput/BWT/plain/model/allocatorはこのbuffer集計に含まず、全process peakは未検証。

fresh `build/khc-quaternary-cts-depth-abba-20261003/` はEXE/report2件のみ。

| file | bytes | SHA256 |
| --- | ---: | --- |
| report.json | 390728 | AE9A4E360507F7CE1A39E87AFE4194CBA8ADDB13ECE0582D0ABE76BF431B30EA |
| depth-o2-yes.exe | 378368 | 0CA1ABB4F9B61E86B569C10B77CC80E1B268EC2A69F53464E1B3035F084DE689 |

実使用769096B（約0.73MiB）で8MiB以内。parent最終照合時空き82440867840B。root通常directory、専有process0、input/frame/plainコピー・temp/bak/debug/PDB/Cargo target/trace生成0。元の失敗reportを含むdepth調査4 output root合計2332061B（約2.22MiB、source・文書は別）。再現証拠以外の大型生成物を作らず、旧証拠・shared cache・x86を削除していない。

## 実行前に解消したハーネス不一致

workerのnonExecute/PSparser/Rustfmt6件はpassedだったが、親の全runner差分レビューでValidate-ABBA定義に対しExecute呼出が旧Validate-Sweepのままと判明。初回compile/CLI前にFAILURE_PLANへ失敗条件を追記し、親がcall名1箇所とplan pinだけを修正した。PS関数定義/call静的照合と106closure/6Rust syntax/full nonExecuteを再確認してから、初回Executeを1度だけ行った。候補CLI失敗・再測定は発生していない。

| final source | bytes | SHA256 |
| --- | ---: | --- |
| probe.rs | 11269 | 6BD241C756EA52EDDBDBD41FC6AB9F522964F98BFE8921D5CA88123C74D74C27 |
| verify-depth.ps1 | 60846 | 30413849F2361E00D5388A8F006CA04B294B05A79FBF3E6CE7FEBE70F021A86F |
| FAILURE_PLAN.md | 5269 | C7E1F5C099267C547511E70DFFD7AC309BACE533FA3857C234F8AB23EA70A061 |

## opop観点・残作業

| 観点 | 親の判定 | 根拠 |
| --- | --- | --- |
| Modernizer | 現状が最適 | toolchain/依存を凍結し、不必要な更新なし |
| Normalizer | 現状が最適 | source alias/import graph維持、旧validator callは実行前に統一 |
| Performance | 改善を採用（研究基点だけ） | size/完全復元を保ち、同一binary ABBAでdepth5の両平均方向が短い |
| Cleaner | 現状が最適 | 大型disk生成なし、必要な旧証拠だけ保持 |
| Hardening | 現状が最適 | guard/CRC/CAP/拒否原子性/120秒/容量上限維持 |
| Tester | 改善を採用 | 全plain比較4回、再出現2frame全byte比較、106identity前後/live |
| Async | 現状が最適 | singlethread、RAM寿命とchild/finally解放を確認 |
| Startup | 証拠不足（優先しない） | 全process peak/現model init時間は未測定、巨大事前tableを作らない |
| Intel | 非該当 | 凍結ローカルの算術・実測で判断、外部現在仕様なし |

実装担当worker-highはrole設定gpt-6.1-sol/high、読み取り専用の次候補調査analystはgpt-6.1-sol/medium。編集所有を分離し、返却・編集停止後に親が引き取り修正/実行した。実効モデル値の外部観測はしていない。

次は `QUATERNARY_CTS_POST_DEPTH_CANDIDATES_20261003.md` のPERF-POOL-QCANCEL。共通Qのexactキャンセルでp正規化のu128商/余りを減らす案を、コード前失敗計画・直接旧新算術/全frame/復元/拒否原子性のE2E・同一binary ABBAで単独検証する。未実装・未測定であり、速度改善を先取りしない。正式速度/CPU/holdout/4native/製品統合は残作業。
