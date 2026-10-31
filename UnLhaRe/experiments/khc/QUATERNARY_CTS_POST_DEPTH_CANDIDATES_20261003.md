# 浅いCTSの次の性能候補（静的調査・未採用）

## 判断

depth5でも固定入力の枝数3825340は減らない。深さに依存しないpool計算と、9段固定のRawSnapshot/seal領域も残る。旧phase sample比率は以前の実装・選択subsetの観測であり、現在の時間へ外挿しない。まず同一binary depth8/5 ABBAを完了し、その後はPERF-POOL-QCANCELを単独候補として先に検証する。以下は静的候補で、実効時間・最終採用・製品統合は未検証。

## PERF-POOL-QCANCEL（推奨する次候補）

対象は `quaternary-cts-integer-pool/integer_pool.rs:25`～`:27` のp生成だけ。qは直前のHamilton normalizeから得られ、active qは0を含めQ以下・inactive0・sum(q)=Q。prefix kは1～4。現在m[j]=4095*k*q[j]+Qを汎用u128 normalizeへ渡している。

- total(m)=4096*k*Q、旧商floor(m[j]*Q/total)=floor(m[j]/(4096*k))。
- 旧余りはQ*(m[j] mod (4096*k))。共通の正倍率なので余り順位とchild昇順の同率優先は変わらない。
- m[j] <= 16381*Q < 2^46で、checked u64のmass・商・余り・Hamilton配分が可能。
- qの0を新たに拒否してはならない。pは既存のuniform floorを足した後のvector/minimum/CDF検査をそのまま保つ。

汎用normalizeと旧sourceは変更せず、新しい小さな研究候補のpoolだけでQをexactキャンセルする。単なる低精度化やrounding変更ではない。scores/ln/exp/q/observe/CDF、固定frame/wire、各種拒否・原子性は不変とする。ソース上では各枝1回の汎用p正規化とactive child分のu128商/余りを削減できるが、コード生成後の削減・総時間寄与は未測定。

コード前に失敗計画を固定する。prefix1～4、qの0/Q、inactive0、sum=Q、Hamilton同率・残数境界を旧normalizeと直接比較する小さなE2Eを用意し、その後は全frame直接比較・全plain復元・Proof/stats/CDF bits一致・model/Snapshot拒否後全state一致を比較する。巨大table、生trace、fixture-specific tuningは不要。最大反証はln/exp・CTS posterior等の支配で総時間がほとんど変わらないこと。同一binary旧/新ABBAでだけ判定し、無計測正式gateの達成としない。

## PERF-ALPHA（後順位）

対象は `quaternary-cts-q32/integer_cts.rs:55`～`:68` のposterior_switchと`:89`～`:93`のupdate_kernel、現depthの`:136`。同じafterに対するalpha=Q/(after+1)とretained=Q-2*alphaを各段で再計算する。depth5ではソース上5回/枝、共通計算1回へ移す候補。固定3825340枝では19126700回から3825340回となるが、compilerが既にhoistしているかは未確認。

実装するなら新研究側のupdateだけで共通化し、各段の入力検査・posterior/next算術・拒否理由順・CAP・pure predict・全prepare後commitを維持する。afterは入口で1～CAPを先に検査している。depth0では旧loopがなく、未使用共通計算による新たな拒否や公開算術変更を入れない。変更前後の全frame/復元/stats、modified/stale/foreign/rebased/CAP/priority/拒否原子性を比較する。u128 posterior本体は残るため大幅短縮を推測しない。

## 採用しない近道・調査境界

seal fastpath・完全visible/certified比較・current guard・CAP・priority・atomic observeは維持する。Snapshot header/rawを省いて、visibleを現在stateへ書き換えたtokenのderived値を無条件に正当化してはならない。固定9段の表現縮小は別のRust表現/API評価が必要で、今回候補に混ぜない。

読み取り専用analyst（role設定gpt-6.1-sol/medium）の返却を親が算術と呼出元から確認した。編集/build/CLI/benchmark/Git/外部調査なし。外部現在仕様は今回不要。既存product/x86/version/shared cacheと凍結証拠を触っていない。正式速度/CPU/holdout/4native/製品統合は未検証のまま。
