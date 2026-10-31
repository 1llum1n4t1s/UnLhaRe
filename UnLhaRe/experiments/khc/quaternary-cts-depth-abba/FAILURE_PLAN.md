# CTS depth8/5 ABBA: コード前固定の失敗計画

改訂契約SHA5617F19FE3D9325E6D7737FB898A218F8350926AE521D751A1E370FAD7CAAABEに従う。新3ファイルのみ所有。旧数値source・wire・timer・comparison/selfcheck・証拠を凍結し直接参照する。ワーカーはPS parser/Rustfmt stdout/nonExecuteまで。型/compile/候補CLI/Executeは親のみ。

## 許可harness差分と失敗条件

mid probeのcodec/comparison pathだけ旧midへ変更、root aliasと旧CTS pathを維持。ABBA順[8,5,5,8]1周、各depth encode/decode2回。再出現frameは1回目のVecをmoveしてRAM保持し、2回目との全byte直接比較後にcurrent/reference両方をdrop。Vec clone、frameのdisk保存、digest-only比較、codec数値body・timer境界の変更は失敗。

持ち越すreferenceは最大2枚/953484B、current candidateは別1枚。候補frameの各call比較直前count/bytesは[1,2,3,2]/[474734,953484,1432234,949468]。保持後reference count/bytesは[1,2,1,0]/[474734,953484,474734,0]。candidate frame bufferの最大3枚/1432234Bを実際のVec長から計測し、最大reference2枚/953484Bと区別する。旧baseline474730B、input、BWT/plain/model、allocator内部を含む全process peakは別で未検証。index2 B比較直後にold/current Bをdropしてから次call、index3 A比較後に全reference0を確認。

## 固定E2Eと全byte比較

旧mid comparison/selfcheckをそのまま参照する。sealed392/223/22、depth[4,5,6,7,8]30/1070/90/pure5/constructor2/compact60。selfchecknormal/plain/canonical各70、malformed165/short20/model named70/assertions80/CAP5。既存exact reason・原子性・純粋性・foreign/rebased・unused zero・CRC depth guardを維持する。

ABBA入力2811006Bと旧baseline474730Bを各attempt/success1でRAM読む。call/plain/stats各4、毎回全plain2811006B直接比較と全Proof/CDF bits/stats一致。A各2回は旧frame bridge24B/474694B。再出現index2 B478750B/index3 A474734B、比較2回/953484B。最初index0/1は比較0/0B。失敗Accountingは実call直前/比較成功時に加算する。protocol再出現は再出現encodeの開始実績、repeat比較attemptとsuccessを分離し、size合格はrepeat比較より前の判定成功時に数える。正常時repeat attempts/success各2、size合格4。失敗後も成功record数から実績を推測しない。

A固定frame474734/header285/payload474449、CRCplain433441561/payload3589341169/header433030689、base9128444225deabce、CDF3788636.714502990±1e-4。B固定frame478750/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052±1e-4。共通grammar/count/classesはmidと同じ。runnerで両encode/decode statsを固定値照合する。size<=483599は毎回必須、4回合格。数値・復元・size・全byte・固定stats・順/件数相違は失敗。

warmup0/ABBA cycles1/protocol再出現2/additional repeats0/inner timers0/full input canonical再encodeなし。計時は旧codec encode/decode callのみ。保持・比較・drop・JSONはtimer外。平均や短縮の解釈はこの診断1周に限定し、正式速度/CPU/統計的優位/全process peak/7-Zip総合超過/製品採用を主張しない。

## closure・容量

mid result SHA7DC6207567024CA7926A34DDC37893F4C4E146C21849D9DDDCC19CBDCE393792、report360935B/SHA161FA2175DAFEE83507F321969D79F753363F8E6BDE073987EED861CF481E27A、EXE375296B/SHABBEC5C2D04F99F7B6AA70071C90059D1E94D35634EBC7CDE5E1DE2C7B8C82B56をpin。mid runner SHA30D74EE571FF980CAE9AA7445920BA445D581B5503DF3B0D71E02F8F2480FA8Fも保持。旧99+new3+契約1+result/report/EXE3=unique106、旧99/EXE before/after/liveと89/84/72/60/48を継承照合。旧Execute/EXE再測定なし。compiled13sources/12edges/root10/unique12、new probe+旧mid codec/e2e/comparison+旧CTS/model。root alias・未pin import・identity相違で停止。

RustSyntax6件=新probe+旧CTS/model+旧mid3Rust。fresh build/khc-quaternary-cts-depth-abba-20261003、上限8388608B、EXE1048576/report524288/scalar予約1572864B、空き5GiB+予算、開始/終了guard。nonExecuteでrootを作らない。親Execute1/compile1/compare-snapshot1/selfcheck1/ABBA1、child120s/stdout stderr各64KiB、raw/parsed保存後validator、kill/dispose/finally、source/EXE identity照合。最終EXE/report2件のみ。既存root/reparse/混在/容量超過は停止、input/frame/plain/temp/bak/debug/PDB/Cargo target/trace生成0。

正式速度<574.5624ms/CPU<=15%、holdout/categories、4native、製品統合は未検証。Git stage/commit/push、version、外部書込み、x86、shared cache、子agentは扱わない。

## 親レビューでの実行前修正

worker返却後・初回Execute前に、validator定義はValidate-ABBAだがExecute呼出は旧Validate-Sweepのままと確認した。PS parser/nonExecuteではこの実行経路を検出しない。コード修正前に本記録を追加し、呼出だけValidate-ABBAへ統一する。親は定義・呼出の静的照合、plan pin更新、全preflightを再確認してから初回Executeを行う。旧証拠・数値body・計時・許可件数・fresh rootは変えず、候補CLIの失敗や再実行はまだない。
