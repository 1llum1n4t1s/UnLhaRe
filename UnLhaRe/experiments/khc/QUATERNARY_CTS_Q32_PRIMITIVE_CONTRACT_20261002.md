# categorical CTS整数primitive: 実装前契約

## 根拠・段階の境界

CTS f64機会proof BA991A3240D62B5512504DFFDC80240D0F0306491CD00D12CFCC8A61C12F3DA2はmixed+escape3794574.025516505bitsで固定予算3866504bitsを通過した。結果正本 QUATERNARY_CTS_RESULT_20261002.md SHA3AFF7A2E9274AA7A3753AC32C8CE9C73CCBF21E0726CED20634701E466DF514E。ただし実frame/速度/portable wireを証明していない。

本段階はcategorical CTS単独の新Q32数値仕様を確立する。旧binary Q32 helper、浮動小数点spec、5feature pool、range coderを同一視しない。ln/exp/勾配/CDF/整数全入力機会gate/実frame/正式benchmarkは次段階へ分離する。モデルのrounding仕様だけを定め、topology/6class/depth8/history/観測capは前契約を維持する。size/速度/CPU/holdout/categories/4native/製品APIの固定総合条件を緩和しない。

新source dir quaternary-cts-q32/、fresh root build/khc-quaternary-cts-q32-primitive-20261002。一人がinteger_cts.rs、primitive_audit.rs、verify-primitive.ps1、FAILURE_PLAN.mdだけを所有する。コード前に失敗計画を保存する。旧source/proof/rootは変更しない。

## 固定整数仕様

Q=2^32をu64で保持する。legal prefix K1..4、合法vector値1..Q、sum=Q、非合法tail=0。prefix1は[Q,0,0,0]を受理する。weightsは0..Qを受理し、初期Q/2、leafはQ/2固定。node raw observations[0;4] u32、class observations u32 cap3825340、rescaleなし。6class×87381node、history u16/最新childから8段のheap pathを継承する。

正規化は最大剰余法（Hamilton法）に固定する。正の合法masses m_jとtotal Mに対して q_j=floor(m_j*Q/M)、remainder r_j=m_j*Q mod M。Q-sum(q)個の残余をr降順、同値ならchild昇順に各1配る。個数はK未満。全積・剰余計算はchecked u128。非法tailは0。汎用normalizerは非負massも扱えるが、CTSのKT/mix vectorの合法値は正でなければ拒否する。zero total、不正prefix、積/合計overflowは拒否する。

KT massesはraw_j*2+1、合法totalは2*sum_legal_raw+K。node全raw totalのcap検査は合法prefixの外側も含めて行い、予測前に拒否する。KT vectorを上記normalizerでQ32化する。

leaf mixed=KT。depth7..0について更新前snapshotのweight w、KT k_j、下段mixed c_jからrawmass a_j=w*k_j+(Q-w)*c_jをu128で計算する。sum(a)=Q²、最大Q²=2^64であるためu64積を仮定しない。mixed vectorも上記normalizerでsumQとする。rawmassはsnapshotに保存するか同snapshotから再計算し、posteriorの分母には丸めたmixed_j*Qを使わない。

class before=n、after=n+1。alpha=floor(Q/(after+1))、retained=Q-2*alpha。選ばれたchildのposterior=floor((w*k_child)*Q/a_child)、next_weight=alpha+floor(retained*posterior/Q)。すべてchecked u128経由、結果posterior/nextweightは0..Q。alphaは1以上で、nextweightは[alpha,Q-alpha]内。leafweightはQ/2、全9nodeのraw childを各+1、その後observations/historyをcommitする。forcedprefix1でもswitch/count/history更新する。

予測APIはclass/prefixだけでobserved childを受け取らない。class/history/observations/node IDs/count/weightのsnapshotは現在値と一致しなければ更新前に拒否する。invalid class/prefix/child、stale snapshot、node/class cap、overflowの拒否時は全状態を直接比較して不変を確認する。hashだけで非mutationを主張しない。全更新の妥当性とallocationを確認してからcommitする。

## 独立検算・事前失敗条件

整数oracleは独立half-count[1;4] u64、別履歴/path（除算/剰余）、別配列/更新式を持つ。主normalizer/ratio/updateを呼ばず、固定128stepのbinary long division等の独立div/remで商・剰余を検算する。剰余配分は別ranking手順でtie規則を比較する。全9level vector、path/count/weight/history/observationsと終端全2621442値をbit-exactで比較する。oracleへ主snapshot/stateをコピーして自己一致させない。

- 全65536historyの9level pathと最大heap index、全classの分離を検証する。
- raw0..5の全1296 vector×prefix4=5184 KTケースとcap境界を検証する。非合法countが合法分母へ混入しないことも確認する。
- weight0/1/Q/2/Q-1/Q、prefix1..4、均等・非対称・cap寄りKTのmixture/posterior/switchを独立整数oracleへ比較する。forced1、初回alpha=Q/2、最大観測直前、最大剰余tieの順序を含める。
- 小depth0..2の全historyと全prefix/合法child、stationary/repeated/alternating/wrap系列を本体kernelへ通し、別再帰計算と照合する。検算用の手書き実装だけを通って本体を検証したことにしない。
- invalid/zero/overflow/cap/stale snapshotを実更新入口で拒否し、全state直接比較で不変を確認する。公開製品APIのセキュリティ保証とは区別する。
- 浮動小数点版の事前tol2e-10は変更しない。新Q32仕様のbit-exact一致と局所丸め誤差を別に記録する。同じraw countsとQ32 weightsを実数として評価したKT/深さ別再帰mixとの差の事前上限は2*(depth+1)/Qとする。posterior/switchの4/Q上限は、既にQ32化したKTと下段mixed、同じweightを実数としてrawmassへ評価した一更新だけに適用する（alphaは実数1/(after+1)）。raw countsから再帰計算した理想f64 posteriorや別連続系列への4/Q一致は要求・主張しない。独立f64連続系列との軌跡同値や集計entropy一致も未検証。実数比較は数値診断だけに使い、encoder/decoder kernelへ持ち込まない。

親の独立BigInt depth1 fixture（prefix4, root raw[3,1,2,0], child raw[0,0,2,0], weightQ/4, before6, observed0）:

- KT [1879048192,805306368,1342177280,268435456]
- child [536870912,536870912,2684354560,536870912]
- mixed [872415232,603979776,2348810240,469762048]
- posterior2312674697、alpha536870912、next2271376934

同じrawとweight/before/childのprefix2 fixture:

- KT [3006477107,1288490189,0,0]、child [2147483648,2147483648,0,0]
- mixed [2362232013,1932735283,0,0]、posterior1366580503、next1561806289

これらは局所kernel fixtureであり物理的な全history状態の再現とは主張しない。数値上限や仕様を実行結果後に緩和しない。整数primitive成功は機会gate通過ではなく、full benchmarkは常時許可しない。

## 容量・識別・実行

one opt2/overflowyes、rustc1.98.1/bundledpwsh7.6.5、debuginfo0 /DEBUG:NONE。parent最終source/runner/hash確認後にcompile/runを一度だけ行い、同条件retryなし。fresh8MiB cap、予想400KiB以下、EXE1MiB/report512KiB予約、child120秒/各stdoutstderr65536。結果はEXEと小JSONだけ、全state/トレース/frames/Cargo/PDB/cacheを保存しない。guard前後確認は強制write quotaではない。

実import graph/source/compiler/runtime/contract/f64source+proof/result/guardをpin/readlock/前後hash照合し、未知import/includeとfresh root再利用を拒否する。f64 cts_model.rs 4054EA03592A0D0548E20B1897EBE678BF0B5F901C5E23F3CDBC8B564BFD97A8は参照資料であってcompile importではない。main/opportunity EA212C9326C62C6D420E2B1A738B0D8B3C63A39C75AB12B1682F388303FD98F3も変更しない。

失敗時は最小JSON/EXE/sourceを保持し、再試行で既存証拠を上書きしない。stage/commit/push/version/公開/外部書込/x86/共有cacheは禁止。製品変更/正式性能/4native/holdout/categoriesは未実施と明記する。全goalはactive・未達のまま。
