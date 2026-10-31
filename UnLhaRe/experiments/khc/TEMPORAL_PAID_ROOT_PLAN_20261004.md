# 固定tile root packet：先行費用診断計画

独立analystの候補P1をprivate情報診断として採る。成功予測・製品採用ではない。全GOAL（完成書庫483599B、CLI encode574.5624ms/decode47.3884ms未満、quiet/warm1+9/holdout/API/4native）を維持する。製品dirty、全旧証拠、Git/version/依存/x86/外部/削除は変更なし。

## 保存費の問い

既存class2/5の278モデルを14反復すると最小14*278*(4+ceil(93/8))=62272B。全284nodeなら63616B。この方式限定の下限であり、全形式の下界ではない。新形式は各tileのcomponent0..1/node0..141/prefix k2..4を固定順の852rootにし、各rootに1bit default/explicit。defaultは原Hamilton quantize([0;4],k)で、k3の丸めを保つ。空root、またはFitの無分割rootがdefault CDFと完全一致する時だけ省略する。任意にuniformへ置換して損失を変えない。

explicitは既存depth5四分木/split bit/15bit頻度そのまま。根ごとの長fieldやbyte paddingをなくし、tileにu32LE有効bit長1個と末尾zero padding1回。全default最低14*(4+ceil(852/8))=1554B。M=sum(4+ceil((852+explicit木bits)/8))、費用screen=ceil(Lparsed/8)+M+3079。無料Qtoken449308Bからの増分＋M<=31212Bが情報条件。raw-bit DPはtile padding込み最適とは主張しない。

## 所有と実装

親は本PLAN/runner/readonly/RESULT/判断を所有。workerは新 temporal-paid-root/{FAILURE_PLAN.md,paid_model.rs,packet.rs,tile_accumulator.rs,e2e.rs,probe.rs}6filesだけ。failure-first/apply_patch、既存source・全証拠不変。他作業者の変更を戻さない。workercompile/native/追加委任/Git/外部/削除0。全保存＋非書込syntax後READY/停止/全hashを返す。

paid_modelはclass-selective-static-mdl/model.rs原全文を保持し、root単位serialize/parse/lookup・uniform判定APIを末尾へ追加する。原quantize/Hist/Fit数値/DP/既存parseを変えない。新packetへ必要なroot単位Reader/Writerは新型で追加し、同数値の旧private write_node/parse_nodeまたは原ロジックを参照する。追加関数だけで済まないvisibility変更が必要なら親へ戻す。

tile_accumulatorはtemporal-node-information/tiles.rsのheap版から、flush前にpacket::evaluate_tile(Dense)を呼ぶ接続と有界14件PaidStatsのみ追加。元history/record/集計/clear順を変えず、元全文へ可逆復元できる変更ledgerを返す。probeは原temporalと同じread1/BWT1/grammarwalk1、旧grammar/counts/model/frontend/BWT/memoryを直接参照。原分布のQ集計には原branch-history modelを使い、paid_modelと名前を分離する。

## 費用・復元の測定

Dense1個をtileごと再利用。clear前に各nodeのweighted Hist→Fit→root serialize/parse、全k/history1024で全CDF直接比較し、packetへbit連結。最大1tile packet/1node scratchだけ、全tile forestや全CDF traceは保持しない。完全packetを再parseして852rootちょうど・bit境界/paddingを確認し、Dense row counts×parsed CDFからlossを再計算。DP lossとparsed row loss、node/component/tile/wholeのcounts/lossを1e-6bitで比較する。Fit→個別root parseの全CDF直接比較と完全packet→観測row loss検査を区別する。

完全packet連結のroot bitsを局所serialized rootと直接比較するか、同じnodeのFitと完成packetの全CDFを再比較する。hashだけでこの連結正当性を主張しない。完成packetがrootごとにCDFを正しく指すかの証拠が必要。原Meta全字段と無料Qlossは旧成功rawを親runnerで照合する。paid費用を無料CDF情報gainへ混ぜない。

原grammar/run/history/幅65536を維持し、14tile/3976node models/11928roots/12214272全CDF比較を固定。frame encode/decode0。packetはRAMのみ、実header bytes/bitsとpadding、default/explicit roots、DP/parsed loss/token ceil/header/side/paid screenを保存。headerだけが大きければ根拠としてno-go、数値不一致は実装不具合として修正する。

## 先行有限E2Eと資源

先にFAILUREへ件数・strict理由を決める。原temporal境界65536/65537、24拒否/回復、実Front3例は直接凍結参照または同fixture維持。新packetでは全default（k2/3/4 CDFを独立算術確認）、非uniform各k、depth5 split、bit/byte境界、正準padding/長field破損/切詰め/余剰/悪CDF/depth超過/上限を扱う。serialize→parse→全CDFと独立weighted lossの有限oracle、拒否後正常復帰。post-code unit testsを追加しない。

max tile payload ceil((284*142335+852)/8)=5052999B、packet with field5053003B。全tile分を保持しない。Dense13959192＋summary276016＋Hist65544＋Fit131064＋Dispatch24600＋root local17816＋packet5053003＋reserve4194304≈23721539B<24MiB。実capacity式を報告、fixed phase48MiB/BWT141598926B/process WS/private各160MiBを維持。巨大Summaryはstackに置かない。

source closure+PLAN+FAILURE<=300KiB、EXE<=1MiB/report<=256KiB/stdout64KiB/stderr16KiB/output8MiB/free5GiB。将来未使用build/khc-temporal-paid-root-20261004にEXE/report2filesのみ。raw input/frame/plain/CDF/packetファイル・Cargo/PDB/ASM0。親全文確認後compile1/native1、固定rustc/pwsh/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、60/120s、原bounded helperとbefore-after-live pinsを使う。今回worker段階は実行0。費用screen成立でも実frame/decoder/速度/quiet/holdout/portable/7-Zip達成は別工程。
