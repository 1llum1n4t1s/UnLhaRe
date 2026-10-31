# node-history information：コード前の一設定診断契約

2026-10-04。QUESTION SHA E6D461FB0BEE4C6A60B8A7A820B920D4B7397496FB309264E16C2FE61D03661F。対象は新private `node-history-information/` と未使用 `build/khc-node-history-information-20261004/` のみ。凍結branch-history-mdl/過去実験/製品/公開API/wire/version/依存/Git/x86/既存dirty差分は変更しない。これは新方式採用ではなく、保存分布を無料にする楽観情報診断である。

## 失敗を先に列挙

component/node/prefix/historyのalias、callback node追加でTree/Front grammarが変わる、node数の手計算が違う、prefix1のhistory更新落ち、現在childや未来tokenを条件keyへ混ぜる、非合法tail/shape/CAP/overflow、拒否前の部分変更、hist総countと枝不一致、entropy/Qlossの非有限値・再walk不一致、未来trained metadataを無料のまま実圧縮と呼ぶ、capacity/peak/source identity/出力/timeout違反、設定sweep/旧root上書き。

## 固定APIとgrammar

Treeは旧branch-history-mdl/grammar.rsの定義を保存し、`pub fn node_count(&self)->usize{self.nodes.len()}` のaccessor追加だけを許す。walkのcallbackを`FnMut(component:usize,node:usize,class:usize,k:usize,history:u16,child:usize)->Result<()>`へ変える。callback呼出引数追加以外のwalk本文は同一。class6本のhistoryは元と同じで、prefix1もchild0を更新する。Meta型/各fieldの意味は変更しない。runnerは元grammarとの全文変換allowlistと旧Tree source pinを検査する。

`counts.rs`に定数NODE_COUNT=142/HISTORIES=1024/CAP=3825340/ROWS=872448。`Dense::new()->Result<Self>`、`pub rows:Vec<[u32;4]>`、`Dense::record(c,node,k,history:u16,child)->Result<()>`、`Dense::row(c,node,k,history:u16)->Result<[u32;4]>`、capacity_bytes。index=`(((c*142+node)*3+(k-2))*1024)+(history & 1023)`、c<2/node<142/k2..4/child<k、rows.len()==ROWS。support tail0/row sum<CAP/checked child+1を更新前にすべて検査し、失敗でwhole rows不変。high history bitsは無視する（元参照はlast10bit）。現在childはindexに使わない。

Qは凍結branch-history-mdl/model.rsのquantizeを読み取り参照する。各row kをindexから一意に導出し、empirical loss=sum c*log2(total/c)（0count項0）とQ loss=sum c*log2(32768/frequency)をKahan集約。empty rowsは両loss0。row/whole/count/CAP/tail/CDF/finiteを検査し、component loss/count/active rows/pure rows/nonzero cellsを報告する。全rowの数値をJSONへ出さず集約だけ保持する。

## 親の有限診断（counts実装前）

happy/adversarialは親所有、worker編集禁止。5既知Hamilton CDF、Denseゼロと合法両端、component/node/k/historyの独立key、history0と1024の同値、childが別でも同じrowを更新することを観測。全indexのshape/末尾tail/countを照合する。拒否c2/node142/k1,k5/child>=kでwhole rowsをbeforeと比較し、故意のCAP row/nonzero tailも拒否/不変。大きいsnapshotは入力/BWTより前に解放する。新unit testなし、診断入口run()->Result<String>を呼ぶ。

## 一回nativeの固定入力と照合

input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、一read/BWT、Front二walk。初回train（prefix1をcountsへ入れない）、全rows entropy/Q集約、二回目固定分布row lookupによるbranch Qloss。同じ全Meta equality、tokens/runs各889227/escapes742/history1778454/grammar58735a2b7383d755、branches[2725772,1099568]、class[889227,620240,1216305,889227,64372,145969]を照合。両Treeのnative node_count==142をassert。coded3825218＋implicit122==3825340、全row countとcoded一致、Q二walklossとhist loss差<=1e-6bits。

報告するoptimistic screenはceil(empirical/8)+3079とceil(Q/8)+3079。model bytesは保存せず無料で0、未保存modelのadoption=false/frame encodes=0/decodes=0/size/speed/portable/holdout claimed=false。idealの差が1B以内ならf64境界未確定、これで数学的な整数lower boundを主張しない。idealすら固定483599B超ならこのsuffix/node分布で保存費用を払う主経路は支持しない。Qfailでもcoarser partition量子化lossの単調性は仮定しない。passは特徴の容量候補に過ぎず、次の費用込みMDL/符号器/全速度・復元の工程は別計画から始める。設定/深さ/精度sweepなし。

## 資源・実行・所有

Dense raw13959168B+inline24、allocator4MiB込み18153496B<モデル24MiB。Front run capacity1048576*12+input2811006+model24MiB+frontend1369112+allocator4MiB=46123158B<48MiB。親のsnapshot診断はDense×2/27.92MB+余裕4MiB<32MiB、入力前解放。BWTは別phase推定141598926B、全体固定実peak160MiB。boundsはquota保証でなくcapacityと実WinAPI80B終端一回のpeakを区別する。API失敗nullはpass扱いしない。

rustc1.98.1/edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/同audit cfg。compilerとnative pwsh SHA・旧source/plan/evidence/tool/入力はbefore/after/live pin。compile60s/native120s、source300KiB/EXE1MiB/report256KiB/streams64KiB16KiB/output8MiB/free最低5GiB。fresh outputはEXE/report二fileだけ、input/frame/plain/raw event copies/Cargo/PDBなし。初回失敗保持、再実行判断は親、setting自動変更なし。

親：PLAN/happy/adversarial/採否と実行/decision。実装worker：FAILURE_PLAN/grammar/counts/probe/runner、その後RESULT/readonly verifier。workerはcompile/native/verifier実行0、追加委任なし。全source停止READY/ownership返却後、親がrunner全文レビューと一回compile/nativeを行う。workerの後段2file編集停止後、親がreadonly verifierを一回行う。全製品完成ゲートは変更せずGOAL active、通過screenを総合達成へ置換しない。
