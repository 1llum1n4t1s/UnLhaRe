# categorical CTS + 5feature整数pool: 実装前契約

## 根拠と固定範囲

前f64 CTS proof BA991A3240D62B5512504DFFDC80240D0F0306491CD00D12CFCC8A61C12F3DA2は固定entropy機会gateを通過し、約8991byte相当の余裕があった。新Q32 CTS source5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7と数値結果BD045390F92312C188E092F4C221726FF259201CB62BA63C13B4CEC5E4F8EC57/保存出力closure3E50A4A0B3A2C7FE3983BA09D3241C27481B63AE7D05085BAFDAA8CD56B30309は数値primitiveの証拠だけで、旧wrapperはfailed、記録済みEXE実行前identityも欠落していた。この不足を新runnerへ持ち込まない。

次はQ32 CTSと5feature poolを固定整数仕様へ統一して、固定全入力のCDF entropy機会gateまで一回評価する。既存4table/count/hash/rescale、tree/nodeID/limit/rankContext、6class/8child履歴、run側履歴、grammar、escapeは維持する。symbol×recent追加tableは重ねない。旧proof/source/rootを変更しない。整数仕様はf64連続軌跡や旧binary Q32 wireと同一ではない。

新dir quaternary-cts-integer-pool/、fresh root build/khc-quaternary-cts-integer-pool-opportunity-20261002。担当一人がfixed_math.rs、integer_pool.rs、opportunity.rs、verify-opportunity.ps1、FAILURE_PLAN.mdだけを所有する。コード前に全失敗計画を保存する。parentは契約/統合結果を所有する。

## canonical ln/exp（encoder用の演算にf64を使わない）

Q=2^32、内部S=2^48、mantissa grid4096。全unsigned積/合計はchecked u128、signed積/合計はchecked i128。unsigned divisionはfloor、signed divisionはtoward zero。overflow/非法domainは拒否し、結果後の丸め仕様変更はしない。

LUT L[0..4096]はx=S+i*S/4096、t=floor((x-S)*S/(x+S))、t2=floor(t*t/S)から作る。power=t、sum=0としてk0..17（18項）でsum+=floor(power/(2k+1))、power=floor(power*t2/S)。L_i=2*sum、LN2=L4096=195103586505154を必須fixtureとする。

ln_scaled(n,scaleBits): n1..Q、scaleBits0/32。e=floorlog2(n)、base=2^e、pos=(n-base)*4096のdivrem(base)からidx/rを得る。mant=Lidx+floor((Lidx+1-Lidx)*r/base)。signed値mant+(e-scaleBits)*LN2を2^16でtoward-zero除算してQ32のlnにする。idxは0..4095。ln_countはn1..32768/scale0、ln_ctsはn1..Q/scale32。count LUT32769（0は不使用sentinel）とL/E LUTを整数演算で起動時に作り、RAMだけに保持する。計327704byte程度で、raw表を保存しない。

E[0..4096]: x_i=floor(i*LN2/4096)、term=S、sum=S。k1..24でterm=floor(term*x_i/(S*k))、sum+=term。E_i=floor(S*S/sum)。E2048=199032864766437をfixtureとする。

exp_neg(d): d_Q32は0..128Q。mag=d<<16、e/rem=divrem(mag,LN2)。e>=32なら0。他はidx/rem2=divrem(rem*4096,LN2)、interp=Eidx-floor((Eidx-Eidx+1)*rem2/LN2)、result=interp>>(16+e)。exp_neg(0)=Q、d負/128Q超を拒否する。zero開始d=95265423099。この整数格子では((d<<16)-32*LN2)=51136がLN2誤差上界32*145=4640 S単位を上回るので、切捨てる真expは1/Q以下である。前dとの差は-14400。一般的な下向きLN2だけでcutoffを正当化しない。

局所真lnとの差の事前絶対上限2e-8、真expとの差2e-8。ln補間の曲率誤差≤1/(8*4096²)、expは≤(ln2/4096)²/8である。旧f64 tol2e-10は変更せず、新近似のexact整数検算と局所real誤差を別に記録する。LUT前後/単調/端点/invalidと丸めは独立oracleへ比較する。

## 5feature pool・更新・CDF

countsは既存4count rowの全4値が正、各row全total≤32768。合法prefixK1..4だけをfeatureに使う。CTS vectorは合法値1..Q、sumQ、非法tail0。weightsはglobal4608rowの[Q/4,Q/4,Q/4,Q/4,0]初期、各0..2Q。

feature_i,jはi0..3でln_count(count_i,j)、i4でln_cts(CTS_j)。この「count4 + CTS1」だけに固定する。score_j=trunc(sum_i weight_i*feature_i,j/Q)。最大scoreを引いた非負d_jにexp_negを適用し、非負exp massesをHamilton正規化してsoftmax q（合法zero可、sumQ）とする。最大childはexpQでtotal>0。score幅は4*2ln32768+2lnQ=184ln2<128で、量子化誤差を含め128Q内。別構成のfeatureへこの上限を流用しない。

uniform U1/4096: m_j=4095*K*q_j+QをHamilton正規化しP vector（sumQ）を得る。Hamiltonは剰余降順/tie child昇順。合法Pは最低floor(Q/(4096K))で正。

predict(counts,weights,CTS,prefix)は観測childを受け取らない。観測時、同snapshotからfactor=floor(4095*K*q_observed*Q/(4095*K*q_observed+Q))、expected_i=trunc(sum_j q_j*feature_i,j/Q)、gradient_i=trunc(factor*(feature_i,observed-expected_i)/Q)、delta_i=trunc(gradient_i/256)、next_i=clip(weight_i+delta_i,0,2Q)。5個すべてを同snapshotから準備して同時更新する。forcedprefix1はq=P=Q/gradient0/weights不変だが、CTS count/switch/historyは更新する。CTS posteriorへpool loss/weightsを混入しない。

CDF totalF=32768。floor(P_j*F/Q)と剰余から同じHamilton法で総和Fへ配分する。poolのuniform下限より各合法frequency≥2、非合法0。cumulativeはchild昇順のprefix sum。観測childによらず全CDFを先に確定する。range coderやframeは本段階では導入しない。

同整数weights/CTS/countsを入力した理想f64 ln/exp/uniform/gradient/SGDとの局所比較を行う（別f64連続stateを模倣しない）。理想gradientはuniform混合尤度のgradientで、((1-U)*q_observed/P_observed)*(feature_observed-sum_j q_j*feature_j)に固定する。q_realは確率単位であり、事前誤差はabs(q_Q32/Q-q_real)≤1e-6*q_real+8/Q、P絶対差2e-6、gradient絶対差2e-3、clip後weight一更新差1e-5。SGD rateは1/256固定。qの相対+絶対項によりuniform factorの差は約3.1e-5以内、feature幅≤lnQからgradient boundを評価する。2e-3/256+1/Q<1e-5。実行後の上限拡大・grid/rate探索はしない。

整数oracleはraw canonical featuresと各演算の順序/丸めを維持する。normalized count featuresへ変えると整数trunc段階で同値とは限らないため、exact oracleへ勝手に持ち込まない。別tables/counts/weights/CTS histories/halves/pathと別normalization rankingを持ち、主snapshotや主LUTをコピーしない。小数値診断ではbinary long division等の別divremで各kernelを検算する。全入力では有界時間のnative u128を使う別式/構造のoracleへ比較し、primitiveの独立商検算と区別して記録する。

## 実装前失敗計画・固定全入力

ln/expのzero/符号/tie/domain/shift/overflow、級数項数/内部floor、grid境界/ln2/cutoff、LUT単調/同値、score途中trunc、q zero/softmax最大、uniform合法最低、5勾配の符号/負除算/同snapshot、初期CTS weight0の学習/clamp、forced1、CDF総和/正頻度/tie/cumulative、invalid拒否/非mutation、CTS snapshot/grammar/全state、import/環境/pins/容量/失敗後の証拠保存をコード前に列挙する。

全count ln32768、CTS ln境界97件（e0..32の2^e±1をdomain内で、重複を数える）＋grid81941件（e12..32/i0..4096/domain内）、exp32769件（d=i*Q/256,i0..32768）を独立整数/局所realへ比較する。L/E各4097値をbit-exact比較し、cutoff±1/端点/invalidは別追加ケースとして件数を記録する。fixed pool内点10 prediction/50 ideal f64中央差分h1e-5（analytic real gradientのabs2e-6検算）、zero/high/forced/uniform/rare/CTS最低/最大/負clamp正学習を追加する。discrete整数gradientそのものへf64中央差分同値を要求しない。各予測器を独立変化させ、全CDFと5weight更新を別整数oracleへexact比較する。

親BigInt fixture（K4/counts[[1,23,7,5],[8,1,37,2],[31,13,1,9],[3,17,5,41]]、weights初期、CTS=Hamilton([7,31,2,11]), observed1）:

- CTS [589505315,2610666396,168430090,926365495]
- scores [7099625000,9162944343,7694719498,8819051486]
- q [816896114,1320698313,938298535,1219074334]
- P [816958821,1320638021,938331602,1219038852]
- CDF frequencies [6233,10076,7159,9300]
- gradients [5536834830,-5930627186,2144632635,1491736668,5049401124]
- next weights [1095370085,1050575312,1082119295,1079568920,19724223]

固定入力all.group2811006byte SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一回BWT/causal run走査する。元tree66049、独立rank889227、oldflat1778454、grammar58735a2b7383d755、3825340枝、rank2725772/length1099568、prefix/depth、既存4expertの8損失/cold/rescaleを凍結f64 proofへ照合する。mainは新CTS sourceをimportし、oracleは独立half-count/path/weights/native divremを持つ。全branchのCTS各9levelとpool/CDF/5gradient/更新、終端全5808642値をexact比較する。CTS class観測は889227/620240/1216305/889227/64372/145969。系列中の局所real比較は同整数snapshotだけ。

primary gateはCDF entropy（frequency/F）+escape5936bits <3866504bits。Q32 P entropyも別記録するが、それだけでgateを通したことにしない。gate falseなら不採用でframe/正式benchmarkへ進まない。trueでも整数range丸め/actualframe/正式speedCPU/holdout/categories/4native/製品APIは未検証。元483599byte frame/574.5624ms/CPU15%等の固定総合条件は維持する。

## 容量・runner・境界

one opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE、rustc1.98.1/bundledpwsh7.6.5。新root8MiB予算、予想512KiB以下（新math/pool/全入力diagnosticによる見積りだけ変更、予算不変）、EXE1MiB/report512KiB予約、child120秒/各stdoutstderr65536byte。全table/LUT/traceはRAMだけ、EXEと小JSONのみ保存し、Cargo/PDB/cache/frame/restoreを作らない。guard前後は強制write quotaではない。

実compile graphはopportunity/fixed_math/integer_pool/旧integer_cts/旧BWT/旧cdf_modelの6source/5import edgeを予定する。未知import/include/extern crateを拒否し、source/contract/oldproof/result/compiler/runtime/input/guardをpin/readlock/hash前後照合する。親の最終レビュー前はcompile/run禁止、parseとpreflightだけ可。

runnerはEXE作成後すぐreport.executable_beforeへidentityを保存しreadlockする。child recordとparsed auditを検証前にreportへ保存し、途中validator失敗でも証拠を失わない。boundは名前付きscalar値/括弧付きdivisionを使い、単なるparseだけでPowerShell式を検証したことにしない。元failed runnerを通常経路へ再利用しない。fresh root上書き/同条件retry/結果後tol変更なし。失敗時最小source/EXE/JSONを保持する。stage/commit/push/version/公開/外部書込/x86/共有cacheは禁止。全goal active・未達。
