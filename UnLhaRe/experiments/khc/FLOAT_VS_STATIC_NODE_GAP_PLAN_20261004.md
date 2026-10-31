# 実float対静的node/history：コード前の一設定局在化契約

2026-10-04。QUESTION SHA36D080E0C9D9470E3F28C6A56BDDD8665E1FA56CEA7AC896B66436C02E1BE382。新private `float-static-node-gap/` と未使用 `build/khc-float-static-node-gap-20261004/` のみ。製品/公開API/wire/version/依存/x86/Git/既存dirty/凍結rootを変更しない。予測分布の差を局在化する診断で、係数・depth・Qのsweep、feature除去ablation、性能比較、実codecではない。

## 実装前に列挙する失敗

旧modelのfloat alias誤接続、featureが現在child/lengthや未来tokenを漏らす、symbol/length context/previous exponent/recent/run_done順の不一致、class/node/prefix/historyのalias、prefix1 observe省略、CDF支持/区間総和/選択差、教師CDF entropy/base-pool digest/全counterの保存値不一致、静的全rowと再walkloss不一致、component/class/nodeの集計漏れ/二重加算、signed gapを非負lossと混同、RAM/snapshot/capacity/peak/source/出力/timeout違反、事後min routeを無料のまま実候補や速度に読む。

## 凍結接続とcallback

Dense/quantizeは凍結node-history-information/counts.rsとbranch-history-mdl/model.rsを読む。新scope.rsの`use crate::{float_math as fixed_math,float_pool as integer_pool,float_cts as integer_cts,Result}; mod model;`で実float Modelへ接続する。new model.rsはlookup-float-cts/model.rsの全文コピー＋末尾のreadonly diagnostic accessorのみ許可。数値/predict/observe/状態/Tree/既存rejection_checksは変更しない。各float_math/float_pool/float_cts/canonical fixed_mathは原本path参照、旧numeric/codec入口を実行しない。

modelの末尾accessor：`diagnostic_storage()`で実tables/weights/tree Vec容量とsizeof(Model)/Countを報告（全base heap+inline、table4capacity、Count幅、tree node数2）；`diagnostic_class(c,node)->Result<usize>`でcomponent込みclassを読む。CTS/Mathのprivate配列は元sourceの固定寸法から別見積1MiB（構築時canonical tableとの一時重複込み）。accessor以外全文対応をrunnerで検査する。これはnew source原本同値性・診断readoutで製品採用ではない。

features.rsのprivateAPI：Feature {pub symbol:usize,context:usize,recent:u32,previous:(usize,usize)}、FeatureState::new()->Self、peek(context,symbol)->Result<Feature>、commit(symbol,rank,length)->Result<()>。FeatureStateはClone/Debug/PartialEq/Eq、recent0/previous[(0,0);257]。peekはcontext<=8/symbol<257を検査し非mutation。commitはsymbol<257/rank<=256/1<=length<=8388609を更新前確認し、previous[s]=(exponent(rank.saturating_sub(1)),exponent(length-1))、class length1/2/3..4/その他=0/1/2/3、recent=((recent<<4)|rank.min(3)|class<<2)&65535。同source旧run_done数式/順序をallowlistで照合する。

grammar.rsは凍結node-history-information/grammar.rsから、features import/FeatureState初期化/callbackのFeature引数一追加/peek引数一追加/run完了時commit一追加と説明comment変更だけ。peekは現在componentのcontext x・symbol sと、直前runまでのstateを渡す。component0のcontext0、component1は既にrank完了後のexponent(rank+1)。rank/history/Meta/Treeの元数値文は不変。commitはlength event終端時、旧rank/bucket更新より前に行う。prefix1も教師predict/observe・class history更新を省かない。

## 親の先行有限入力

新happy/adversarialは親所有、worker編集禁止。正常はFeature初期、symbol5 rank3 length4→previous(1,1)/recent11、symbol7 rank0 length1→recent176/symbol5 previous保持、symbol5 rank256 length256→previous(7,7)/recent2831、symbol5 rank0 length1→recent45296、2通りのcontext peekがstate不変を全比較。境界symbol256/rank256/length8388609は受理しprevious(7,23)。拒否peek context9/symbol257、commit symbol257/rank257/length0/8388610は全FeatureState不変。

凍結Denseのhappy/adversarial helperを新binaryから再利用し、元input fixture全rows872448/10events/6active/alias2/拒否8を診断する。新unitは書かない。実floatの既存rejection_checks(5)を原本sourceから同じ新Model moduleで呼び、26named/26whole-state comparisons/CAPちょうど成功1を確認する。snapshotは固定入力/BWT前に解放する。

## 単一native

固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。一read/BWT。Front二walk：初回Dense train、次は同じbranch列でstatic Q lossと教師predict/interval/observe。static row全872448のtail/CAP/総count/finite/CDF/row Qlossを原診断と比較する。教師CDFは全legal child interval連続性/総和32768/支持min2/observed childのselect一致を確認し、freqからloss集約、observeは一branch一回。未来観測childはpredictの引数にない。教師Treeのclassとcallback classを照合する。

全Meta equality、runs/tokens各889227、primary1762795/escape742/history1778454/grammar58735a2b7383d755、branches[2725772,1099568]/classes[889227,620240,1216305,889227,64372,145969]/coded3825218/implicit122。static Q4012463.5702508213bits、empirical4012402.2267339313を許容1e-6bitsで照合。教師terminal base_pool_digest=e596183d9e1eb8d7、audit entropy3820764.172789027はf64 to_bitsで原reportと一致、branch/class observations・grammarも一致。新集約teacher Qlossは1e-6bits差以内。

component2/class6/node各142のbranch/coded countsとstatic/teacher nonnegative Q lossesを集約する。class gap=static minus teacherはsigned、class/component/nodeの全loss/count総和を照合。node reportはcounts/classes/staticQ/teacherQの2×142固定配列で約20KiB以内を見込み、raw event/全rowは保存しない。posthoc min routing、saved model、frame encodes/decodes、real_size/speed/holdout/portable claims、adoption全て0/false。side3079は742+285+4+2048reserveの診断式でframe下界ではない。旧binary7class結果をquaternary6classへ転用しない。

## 事前RAMと実行制限

Dense13959192B、Model base counts791040*Count<=16B=12656640B、weights4608*40=184320B、Tree/inline余裕65536B、CTS/Math依存（初期canonical重複込み）1MiB、node/feature/snapshot固定scratch65536B、allocator4MiB。合計32174104B<model32MiB33554432B。実table4capacity=[4608,262144,262144,262144]/Count<=16/trees[142,142]をaccessorで検査しbase actual bytesを上記base/weights/tree余裕に照合する。Modelがsource確定寸法であってもallocator quotaではない。

固定phaseはFront run capacity1048576*12+input2811006+model32MiB+frontend1369112+別allocator4MiB=54511766B<64MiB。BWT別phase見積141598926B、全体実peak160MiB、WinAPI80B/cb80/終端一回、API失敗nullを資源成功へ読まない。fixture Dense snapshotとoldModel拒否snapshotは順番に実行し固定入力前解放（同時保持しない）。

rustc1.98.1/edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/frame_audit+primitive_audit。compile60s/native120s、source300KiB/EXE1MiB/report256KiB/streams64KiB16KiB/output8MiB/free5GiB。未使用outputにEXE/report二fileだけ。元lookup float reportとnode-history report・source/tool/input/plan/fixturesはbefore/after/live pin。closureの実source数/edge数は全graph非実行確認後固定。runtime判定に速度gateは使わず、時刻を正式ベンチ扱いしない。

親はPLAN/fixtures/採否/実行/decision。workerはFAILURE_PLAN/features/grammar/scope/model/probe/runner、後段RESULT/verifierのみ。追加委任/Git stage commit push/外部write/delete/product変更無し。他者dirtyを戻さない。全source停止READY後親が一compile/native、後段二file停止後親がreadonly verifier一度。全encode/decode/resources/holdout/完成書庫/API/4native等のGOALは未達/activeのまま維持する。
