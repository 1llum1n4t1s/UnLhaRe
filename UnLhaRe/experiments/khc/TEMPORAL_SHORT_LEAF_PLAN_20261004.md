# 固定14tile・短いleaf表現と実費DP

親のpaid-root実行は費用532461Bでno-go。次のprivate診断1候補を実装する。全GOAL active、完成書庫483599B/全CLI encode574.5624ms/decode47.3884ms未満/quiet≤15%/warm1+9/holdout/API/4nativeは維持。製品・既存source/report・Git/version/依存/x86/外部/削除0。

## 独立反証と限定採否

独立analystは保存費だけ短縮する案を反証した。現木を固定してheader0でも507396B、23797B超過。root packet最低1554Bならtokenも25351B以上削減が必要。selected leafのCDF別件数は未観測で、無料pure78971行をselected pure葉数に置換しない。新DPで剪定損失を減らせるかを固定1回だけ評価する。成功保証なし、no-goも受理。

## 仕様

原Hist/quantize/固定history/四分木depth5/row lossを維持。tree split bit1個を維持し、leafに2bit mode: 00=原Hamilton uniform、01=canonical pure、10=原15bit raw、11=reject。pureは支持値2、dominant32768-2*(k-1)と全CDF一致する場合だけ。dominant indexはk2で1bit、k3/4で2bit、k3 index3拒否。内部leaf bitsはuniform3、pure4/5/5、raw18/33/48。量子化値や近似を変更しない。

root defaultは既存outer flagのみ1bit。DP root内部費用は0、outer flag常数1として比較し、内部defaultは3bit。DP目的費用0とoracle用root serialization3bitは区別し、独立root parserにbits0を渡さない。選択済みrootのCDFがuniformかつ無分割なら検証用3bitを作って全CDF比較、packetでは省略する。旧serialize/selected_header_bits等のprivate補助もこのoracle wire長と矛盾しないよう明記・統一する。非default rootは通常tree bits。DP選択に使った全root内部bits＋852outer flagsと実header有効bitsを直接一致検査する。padding/u32長は最後に加える、bytepaddingまでの最適性は主張しない。

全展開treeは102399bits/model、原保守MAX_BITS142335/MAX_BYTES17792以内。packet上限5053003Bを維持。wireは旧形式と非互換、新候補kindとsource識別で分離、旧証拠不変。k3defaultは[10923,10923,10922,0]。parseのmode/index/depth/最小頻度/合計/padding/exact bits/duplicate coverage境界を維持。

## 所有と変更台帳

親所有は本PLAN/runner/verifier/RESULT/decision。元workerへ新temporal-short-leaf/{FAILURE_PLAN.md,paid_model.rs,packet.rs,tile_accumulator.rs,e2e.rs,probe.rs}の6filesを独占委任。まずfailure-firstの有限censusを保存、次に実装。元paid-rootからの変換はCDF mode helper追加、Fit.build_node bits目的変更、serialize/write_node/parse_nodeの新leaf表現、root oracle bits特別扱い、packet counters/実DPbits照合、probe kind/counters/newE2E、必要なE2E fixture破損箇所に限定。quantize/Hist/weighted ingest/Accumulator既存record/free集計は元全文保持、原復元可能ledgerを返す。

workerはapply_patchのみ、compile/native/外部/Git/削除/追加委任0。固定rustfmt絶対pathによる非書込syntaxと可逆ledger確認後READY/完全編集停止/6hashを返す。親が全文確認してから実測。元paid-root6filesと全旧reportは変更しない。

## 先行有限E2E・実測条件

凍結temporal E2E24拒否/65536・65537境界/Front3と既存packet正常4/拒否8/root3/weighted4を必要な新wire表現へ適合して維持。新oracleは各k各dominantのpure計9、内部uniform/raw、mode11/k3不正index/truncated tag/index、root default費用0、DP leaf/split費用境界を事前にcensusへ書き出す。独立算術のbits/CDF/lossとFit→root全CDF/完成packet row loss/連結root bit直接比較を実施。新DPは旧selected CDFを保持するとは主張しない。同じhist nodeの原quantize値を保つ。

固定read1/BWT1/walk1、14tile/3976models/11928roots/12214272CDF、width sweep0、実frame0、Dense1/packet1/node scratch1、summary14、forest/trace/diskpacket0。DP/解析損失node/component/tile/whole1e-6以内、元Meta/freeQ全fields直接一致。paid ceil+header+3079を固定483599Bへ比較。token deltaは符号付き、root fee0のreportを実bitsへ独立照合。

model24MiB/fixed phase48MiB/BWTとOS WS/private各160MiB、source+PLAN+FAILURE300KiB、EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、将来未使用build/khc-temporal-short-leaf-20261004に2files/8MiB、空き5GiB。原bounded helper、fixedrustc/pwsh/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、compile1/native1/60秒120秒、before-after-live pinsを維持。親verifierは元wrapper階層誤りを修正済みのvalidatorを用い、再発防止として事前にE2E shapeを確認する。
