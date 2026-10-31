# branch-history MDL：コード前の一設定失敗契約

2026-10-04。親PLAN SHA7956138C4487C6F97114627F2791BC6D5C588FBDB73280822B3A0DF742D9757D、QUESTION SHAB730F06FE3C8F3B7770E451740AA5909F6ECBB5EFD49D9257390D8643D67F0BDを全文読了。trained branch/class/prefix/history MDLの実metadata込み必要sizeだけ診断する。旧direct/convex不採用を変更せず、coder/frame/復号/速度/portable wire/総合到達を主張しない。

| 固定の失敗条件 | 先行E2Eと拒否 |
| --- | --- |
| grammar | 凍結lookup-float-cts/model.rsのEdge/Node/Tree区間はvisibility変更とclass getter追加以外全文同じ。token child/prefix/edgeを同定義で辿り、class component*3+node.class、初期6history0、prefix1のchild0更新も必須。Frontのprevious rank/context/token grammarと枝/classの凍結総数不一致は拒否 |
| Hist | class6/k1/k5/child>=kを拒否。18*1365*[u32;4]、history last10bitの全6pathで更新前checked_addを完了し、拒否で全counts不変。shape/非合法tail/overflow/CAP3825340/親childrenの全child総数差は拒否 |
| Hamilton | k0/1/5、nonzero tail、raw total>3825340を拒否。合法child最小2、残32768-2k、integer floor/largest remainder降順+index昇順。空uniform、single[7,0,0,0]k4、tied[1,1,1,0]k3、空k2/3/4の5CDFfixture。k3=[10923,10923,10922,0]。CDF sum32768/tail0 |
| DP | depth5 leaf、leaf loss+1+15*(k-1)、split 1+4children最適費用、完全tie leaf、空node uniform leaf。空Hist18leaf/558bits/70bytes、h0child0のみ100はleaf、h0child0/h1child1各10000は1split/607bits/76bytes、pure32766/2・未観測h2/3uniform |
| header | class順prefix2/3/4、preorder tag0leaf/1split、MSB-first、k-1freq15bit。depth5 split/empty/truncated bits-1/extra byte/nonzero padding/all0firstCDFを拒否。最後frequencyは32768-sumで>=2。exact bits/ceil bytes、parse全18*1024CDF直接比較、DP selected leaf hist loss vs parsed二walklossを照合 |
| resource | model-header.bin create_new/106752B上限/実bits-size-SHA、source300KiB/output8MiB/EXE1MiB/report256KiB/streams64KiB16KiB/compile60s/native120s/ownedprocess0。初回失敗保持、設定sweep/無許可再実行なし |

private固定API：Hist::new()->Result、pub counts:Vec<[u32;4]>、record(class,k,history:u16,child)->Result。quantize([u32;4],k)->Result<[u16;4]>。Fit::build(&Hist)/lookup/serialize、parse(bytes,bits)->Dispatch/lookup。診断getterはloss_bits/selected_header_bits/selected_leaf_count/selected_split_count/capacity_bytes。親happy/adversarialは編集禁止、workerはcompile/native/verifierを実行しない。全source停止READY後親が一compile/native、事後readonly一回。

## 事前RAM容量式

18*1365=24570hist nodes、counts393120B。Fit全nodeはfrequency8B/split bool/selected loss f64/bits usizeをreprではなくsize_ofで検査、事前node32B上限=786240B。Dispatch18432*8=147456B。header保守854010bits/106752B、serialize+一時packet最大2*106752B。DP buildでcounts借用のみ、再帰depth<=5、parser直接dispatch展開。model同時列挙最大393120+786240+147456+213504+inline/小固定4096=1544416B、8MiB以内。実Vec capacity/size_ofをreportし、allocator余裕4MiBを別加算してもmodel8MiB内に抑える。

固定phase=run1048576*12+input2811006+model8MiB+frontend余裕1369112+allocator4MiB=29345942B <32MiB33554432B。BWTは別phase推定141598926B、hist/fit構築前にBWT scratchは破棄。WinAPI凍結80B helperで終端一回、実peakWS160MiB以内、API失敗は未測定null（pass扱いしない）。推定はquota/peak実測保証ではない。

固定入力一read/BWT、Front二walk（train/parsedloss）、各889227tokens/runs、escape742、history1778454、grammar58735a2b7383d755、branches[2725772,1099568]、class[889227,620240,1216305,889227,64372,145969]。screen=ceil(branchQloss/8)+actualheaderbytes+3079、gate483599。header保存は新metadata証拠で入力/frame/plainコピーではない。policy未採用、4native未検証。

rustc1.98.1 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/edition2024/同audit cfg。旧source/plan/report/EXE参照のみ、製品/wire/API/版/依存/x86/README/Git/外部write/削除/追加委任なし。親が採否を所有し、workerはRESULT/verifier保存後全編集停止・ownership返却。新context独立監査未実施。
