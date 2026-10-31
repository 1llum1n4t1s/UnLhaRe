# KT専用64/32 register形状の反証条件

新native32性能試行はCPU guardによってwarmupで停止し、測定0。速度採用なし。次の数値候補は汎用ratio全体の分岐を増やすのではなく、Node::ktの既知の式へ限定する。まだ実装しない。

## 現在sourceと数学

凍結native32 CTS SHA `27775D82F1A94E013C83A2D42C8A004D7EF507ED09302EB1BB0704DCC798B0A0` は `checked_add(zero,one)` → total<=562036803 → 等カウントQ/2 → 非等カウントratio(Q/2,2*zero+1,total+1) → probability検査の順序。Q=2^32、zero/oneはu32。呼出し元はTree predictのroot及び後続16level、監査はaudit_ktとModel::audit_step。いずれも同じNode::ktを通る。

1. 成功したtotal検査後は0<=zero<=total<=562036803。d=total+1は1..562036804でu32範囲、d<Q。
2. n=(Q/2)*(2*zero+1)=Q*zero+Q/2。したがってnのhigh32は正確にzero、low32は正確に0x80000000。64bit積はoverflowしない。
3. zero<total+1=dなので、32bit商のhardware除算条件high32<dが必ず成立する。任意のhelper引数のガード省略を許可する証明ではない。
4. n>=Q/2、d<=562036804<Q/2なのでfloor(n/d)>=1。n<Q*dなのでfloor(n/d)<Q。通常成功後のprobability boundsも満たす。
5. 既存equal-count shortcutとoverflow/cap error順はそのまま保持する。非等カウントでのnumerator/product overflowはこの検査済み領域では起きず、領域外を検査せずdivへ渡してはならない。

候補はx86_64かつ非forcedportableだけ、Node::ktの成功済み非等カウント枝でEAX=0x80000000、EDX=zero、divisor=total+1のdivlを使う。inout EAX/EDXを予約し別regのdivisor、pure/nomem/nostack、flags保持宣言をしない。非x64/forcedportableは凍結ratio式を保持。posteriorやnext_weightは変更しない。unsafeの前提は同じ関数のtotal検査に局所化し、外部公開のunchecked APIを追加しない。

## 実装前の打切りと検証

- 現在EXEでKT callsiteが既に同形状へ最適化されていたら、source整理だけの候補は作らず打ち切る。汎用helperやposteriorのdivlをKT専用化の証拠と混同しない。
- frozen KT65536 recordsの全域oracle/旧opt2・3 raw及びModel11267 recordsの独立oracleを、通常/forcedportable opt2/3 CLIで再利用して全byte比較。invalid counts（checked_add overflow/cap）、equal counts、zero/one境界も保持する。source/compiler/current direct fixture identitiesをhold/after照合する。
- 正常codecの全frame・復号・既存output/破損拒否を確認。KT専用candidateとして差分が局所化していない、失敗順・wire・layout不一致なら棄却。
- source/math/生成コードの妥当性は速度の証明ではない。quiet/fullCLI/同session比較成功まで採用なし。固定gate/総合未達を保持する。

CPUクロスチェックではraw WMIと独立GetSystemTimesが6区間すべて15%超を示した。以前の41%の原因は未確定だが、現在負荷を単にformattedカウンターの不具合として扱う仮説は支持されない。測定guardを緩める修正はせず、上記の読み取り・数値実装準備へ進む。
