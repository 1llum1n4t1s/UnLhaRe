# 有料root履歴順候補

global minor実費screen487544Bは目標483599Bに3945B不足。近似Δは248.697bitsのみで、精度sweepで埋められる差ではない。独立読み取り監査が成立した低位/高位digit順の有料root選択1候補を新private `root-history-order/` へ実装する。旧global source/report/EXEと製品dirty/Git/version/依存/x86/外部/削除を変更しない。全GOAL active、全CLI574.5624/47.3884ms、quiet/warm1+9/holdout/API/metadata/4nativeは維持。

## 構造・最強反証

grammar履歴は((h<<2)|child)&1023、低位digitが最新。全rootをhigh-firstへ置換すると最新依存の木が深くなるため棄却。固定low-firstとhigh-firstの2構造だけを各node/prefix rootで比較する。全120順/幅/精度/パラメータsweep0。

固定置換Rは5個の2bit digit反転、1024history上の全単射・R(R(h))=h。原grammar/rawhistory/Dense/freeQ/quantize/LUT/leafCDFは維持。high Histへは元historyのRでingest、high Fit lookupとparse Dispatchの履歴対応も同じRを適用。完成Dispatchは元history index、Forestとgrammarの呼出しは不変。現在の低位mask条件をhigh parseへそのまま使わない。

root splitはsplitbit1＋orderbit1（low0/high1）、後の内部splitは従来1bit。leaf/default rootはorderbit0個。DPを作る時にdepth0 split fee2として最適化し、事後+1だけで比較しない。rootごとlow/highのloss+実bitsの小さい方、同値lowを選ぶ。leafのuniform/pure/compact費用3/4・5/12・21・29、default内部費用0/oracle3を維持。outerflagは全834root各1bit、global length4B＋padding1回。metadata/in-memory費用を無料にしない。

高位依存h>>8 fixtureは有料low4438bit/high18bit、最新依存h&1 fixtureはlow18/high4438bit（pureCDF同一）を独立wire/lossで確認。split order追加1bitでleafへ戻る境界を先に有限列挙で固定し、その値を失敗契約に保存してから候補を実装。default/非uniform leafにorderbitを払わない、同node prefixごと混合low/highを確認する。

## 所有・資源

workerのみが新 `root-history-order/{FAILURE_PLAN.md,model.rs,bundle.rs,e2e.rs,probe.rs}` 5filesを所有。親は本PLAN/AUDIT/runner/verifier/RESULT/decisionを所有。原 `global-minor-codebook/` を基点とし、原Hist/quantize/ingest/grammarの数値を維持する可逆ledgerを残す。実装方式はworkerが単一所有で選ぶが、各prefix選択と元historyへのDispatch展開を省略しない。

低/高HistとFitを同時保持する場合のactual capacityを全計上、Dense1/Forest1/packet1/node scratch1を維持。既存model30367073Bにextra Hist/Fit約196608B＋selector等の増分、保守packet増分を計上。model32MiB/phase64MiB/OS WS/private160MiB、scratch65536B/node report36000B/row160Bを維持。old model MAX_BITS142335に3root order bitsまで足しMAX_BITS142338/MAX_BYTES17793、global worst278*MAX_BITS+834bits＋4Bに更新。packet5MiB以内。

学習と完成Forest再検証は両順を構築。distinctmodels278、元histfit556＋高histfit556＝1112 Fit builds（train556＋verification556）。元weighted854016とhigh weighted854016、検証も各854016を別fieldで報告する。原freeQは元lowデータ1回だけ加算し原rawと比較。元/高rootcountsを全1668比較、選択Fit→個別root854016CDF、完成Forest→再選択Fit854016CDF。選択根順/選択split roots/orderbits/葉/default根の費用を独立reportする。

実入力read1/BWT1/grammar2walk、全Meta/directEq原raw一致。combined=選択parsedloss＋旧teacher非選択2286636.8077715bits、screen=ceil(combined/8)+実header+3079。teacher0/frame0/state未検証/in-sampleのみ、速度/採用false。same-selected-tree原Qloss/符号付きΔを各node/component/whole再照合する。node8列と原field意味を維持、追加order fieldsは明示する。

## Failure-firstと親実行

先行FAILUREへ1024置換/逆/独立全CDF、最新/高位依存の対称fixture、prefix混合、leaf/default無課金、split1bit変更のDP境界、truncated order/depth/pad/exact/global余剰/拒否理由/同process回復を固定。旧density happy/adverseは凍結直接参照、新wireでは旧root split fixture/深さfee等を無条件流用しない。post-code unit追加なし。

workerはapply_patchのみ、compile/native/Git/外部/削除/追加委任0、固定rustfmt非書込syntax＋ledger＋5SHA/mtimeでREADY/完全停止。親全文reviewとsourceprefix/ledger/全費用/census確認後にcompile1/native1。fixedruntime/rustc1.98.1/opt3/thin/CGU1/unwind/overflowyes/debug0/frame_audit/primitive_audit、原bounded helperで60/120秒。source+PLAN+FAILURE300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、未使用 `build/khc-root-history-order-20261005/` にEXE/report2files8MiB、free5GiB。入力/metadata/frame/traceコピー0。

基礎global-minor readonly133組開始/終了を維持する。新paid screenが超過、CDF/Meta不一致、予算違反なら棄却。通過時も実teacher状態・実frame往復・サイズ・全速度・holdout/4nativeを満たすまでは全GOAL未達。
