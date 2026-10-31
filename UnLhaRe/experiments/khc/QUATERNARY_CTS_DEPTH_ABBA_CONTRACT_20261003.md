# CTS depth8対depth5: 同一binary ABBA契約

## 固定基点と目的

mid-depthは[8,7,6,5,4]すべて完全復元し、size<=483599Bをdepth8/7/6/5が通過した。depth5がsize合格中で最短だったが単発順序依存の診断である。本段階は深さA=8/B=5の[8,5,5,8]を同一binary内で各encode/decode2回、ABBA1周だけ比較する。実frame・正しさ・既存数値bodyを維持し、正式速度<574.5624ms/CPU<=15%、holdout/categories、4native、製品統合の条件を変えない。

mid result SHA7DC6207567024CA7926A34DDC37893F4C4E146C21849D9DDDCC19CBDCE393792、report360935B/SHA161FA2175DAFEE83507F321969D79F753363F8E6BDE073987EED861CF481E27A、EXE375296B/SHABBEC5C2D04F99F7B6AA70071C90059D1E94D35634EBC7CDE5E1DE2C7B8C82B56を凍結。mid source99件とEXEのbefore/after/live、および旧89/84/72/60/48を継承照合する。旧Executeや旧EXE再測定は行わない。

## 所有と許可差分

親は本契約・レビュー・実行・結果を所有。worker-high一人は新規quaternary-cts-depth-abba/の3件（FAILURE_PLAN.md、probe.rs、verify-depth.ps1）だけを所有し、FAILURE_PLANを先に書く。テンプレートの新候補へのCopy-Item再利用は可。その後の編集はapply_patch。旧source/report/EXE、製品/API/manifest/version、Git、x86、shared cache、外部書込みは変更しない。

probeのcodec/comparison module pathだけを旧midへ向け、旧CTS/model/pool/math/BWT/range/seal/guard/commit/wire/bodyとtimer実装を直接参照する。root alias use reference_cts as integer_ctsは保持。入力/旧frameの上限・read accounting・decode自己記述・直接plain比較・Proof/stats/CDF bits比較・depth8 bridgeは旧probeと同じ。

許可するRust harness変更はABBA順序・表示・実績カウンタ・各depthの2回目frameを1回目のRAM frameと全byte直接比較することだけ。次のcallへ持ち越すreferenceは最大2枚・953484B。current candidateは別に1枚あり、index2のB比較直前は3枚・1432234Bが同居する。Bは比較後にcurrent/reference両方をdropし、index3のA比較直前は2枚・949468Bとなる。clone/disk frame生成はしない。この上限はframe bufferだけで、BWT/plain/modelを含む全process peakではない。比較・保持・dropは既存codecのencode/decode call timerの外。失敗実績は実呼び出し前のAccountingを引き継ぎ、repeat frame比較の成功実績を別に記録する。

## コード前の失敗条件

comparison/selfcheckは旧mid実装を変更せず、旧sealed pair392/223/22、独立depth[4,5,6,7,8]30/1070/90/pure5/constructor2/compact60、selfcheck70plain/70canonical/165malformed/20short/70model named/80assertions/CAP5を同一binaryで再確認する。

ABBA4回のfull plain各2811006B、encode/decode全Proof・stats・CDF bits一致を必須とする。Aのframe474734/header285/payload474449、CRCplain433441561/payload3589341169/header433030689、base9128444225deabce/CDF3788636.714502990±1e-4。Bのframe478750/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37/CDF3820763.985142052±1e-4。共通grammar/count/classesはmid値を維持する。各Aの旧frame bridge24B/474694Bも直接比較する。

再出現frameの全byte直接比較はBのindex2で478750B、Aのindex3で474734B、合計2回・953484B。最初のA/Bでは比較0/0B。入力/baseline各attempt1・success1、encode/decode/plain/stats各4、size合格4、warmup0、ABBA1周、protocol内の再出現2、protocol外additional repeats0、inner timers0。全入力canonical再encodeはしない。出力順/件数/理由/原子性/固定stats/byte不一致・size超過で停止する。frame/plain/digest-only比較を代用しない。

## runner・freeze・容量

旧mid runnerを利用し、旧99件を保ち、新3件＋本契約＋mid result/report/EXE3を加えてunique106。旧mid verify-depth.ps1のSHA30D74EE571FF980CAE9AA7445920BA445D581B5503DF3B0D71E02F8F2480FA8Fもpinする。Immutable-Mid-Depth-Basisで旧99/EXEを照合し、compiled13sources/12edges/root10/unique12はnew probeと旧mid codec/e2e/comparison・旧CTS/model等。root alias/import graphの相違・未許可body変更・identity相違は停止。親は旧probeからのharness差分とrunner差分をすべて読む。

workerはPSparser、Rustfmt stdout6件（new probe＋旧CTS/model/codec/e2e/comparison）、nonExecuteまで。型/compile/Execute/候補CLIは親だけ。親Execute1/compile1/compare-snapshot1/selfcheck1/ABBA1。rustc1.98.1/edition2024/frame_audit/primitive_audit/opt2/overflow yes/panic abort/debug0/DEBUG:NONE、child120秒/stdout stderr各64KiB、raw/parsed保存後validator、kill/dispose/finally、source/EXE前後・容量guardを保持。

fresh build/khc-quaternary-cts-depth-abba-20261003、8MiB上限、EXE1MiB/report512KiB/合計予約1572864B、空き5GiB+予算、最終EXE/report2件のみ。nonExecuteでrootを作らない。input/frame/plain/temp/bak/debug/PDB/Cargo target/traceをdisk生成しない。既存root/reparse/混在/容量超過は停止し、旧root上書きや無制限retryは行わない。

## 解釈と完了条件

同一binaryのABBA各2回平均と実frame/node領域を診断として比較する。A対Bの時間短縮は、この1周の観測にだけ限定し、正式改善率・統計的優位・全process peak・7-Zip総合超え・製品最終採用としない。合格なら次の性能設計の基点にdepth5を暫定選択できる。速度が両方向で改善しなければsize合格候補のまま保留し、数字を良く見せるための再試行をしない。
