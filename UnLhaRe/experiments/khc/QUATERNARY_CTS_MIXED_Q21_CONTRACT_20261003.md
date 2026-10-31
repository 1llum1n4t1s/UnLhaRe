# 別研究形式: mixed Q21の固定実装・E2E・条件付きABBA契約

## 基点・範囲・未達条件

新private形式の候補1件を作る。意味保存の最適化ではない。基点はdepth5旧Q32 CTS/旧pool/旧Q48→Q32 Math。QCANCEL、Math-U64、Alphaは未採用で混ぜない。製品、公開API、version、Git、x86、共有cache、既存dirty changes、固定source/契約/result/EXE/reportは変更しない。goalはactive、正式7-Zip総合超えは未達。

参照済みAlpha RESULTのSHAはF3FE919A18CD98A2C735A4B8502110DF30E37C95BE1104229E6A26D8E5872067、mixed feasibilityは44FB4B26E1F40DFD376E568DBD17F65878885ED322B74A0AA9ED49EB1FD39DF2。Alpha reportは66CAFD4526241B1A13C83754FCE142F976344ECBC0E817405CCC68DFEA26E663、362487B、sources/source_after各149件、passed。その149 identitiesを前後/liveで保持し、既存証拠を再生成・再Executeしない。

新編集の所有はworker-high1人に限定。対象は `quaternary-cts-mixed-q21/` の11file: FAILURE_PLAN.md、integer_cts.rs、integer_pool.rs、model.rs、codec.rs、baseline_codec.rs、e2e.rs、oracle.rs、comparison.rs、probe.rs、verify-q21.ps1。親が本契約・結果・実行・採否、独立readonly担当がコード確認を所有する。所有外の不足は親へ返す。workerはcodeより先にfailure planと全E2E入力・期待値/拒否・計数を保存し、非実行検証後に編集停止・所有返却する。unit testは追加しない。

## 新数値policy（変更しない）

| 項目 | policy |
| --- | --- |
| 形式 | 8byte magic `KHQCMQ21`。Q21、KT最低1予約、alpha最低1、Math32、学習順、feature domainをこのmagicで固定。header配置・depth field・CRC・packed alphabet・BWT・rangeは既存形式から不変。旧KHQCID01、KHQCIP01、未知magicはheaderで拒否。公開wireへ導入しない。 |
| 確率 | Q_PROB=1u64<<21、CAP3825340、classes6、levels9、depth0..8。各active CTS/p値は1..Q、inactive0、全和Q。node rawは全4要素和をCAP検査。 |
| KT | active childごとに1を予約し、残量Q-prefixをmass=2raw+1へHamilton配分。floor後のmax1再正規化は禁止。余り降順、tie child昇順。prefix1はQ。 |
| mixture | weight∈[0,Q]、mass=weight*own+(Q-weight)*child、全mass=Q²。通常HamiltonでQへ配分、正値を再検査。KTに用いる予約方式をmixtureへ混入しない。 |
| posterior | ownmass=weight*own、rawmass∈[max(1,ownmass),Q²]、posterior=floor(ownmass*Q/rawmass)。alpha=max(1,floor(Q/(after+1)))、retained=Q-2alpha、next=alpha+floor(retained*posterior/Q)。after1..CAP。depth0の空loop・guard優先は旧kernelを維持。 |
| Math | 凍結 `quaternary-cts-integer-pool/fixed_math.rs` を変更せず参照。MathのQはQ_LOG=2^32、Q48表も不変。CTS値はvector検査後checked_mul(2048)でln_ctsへ渡す。checked_shlでoverflow検査したつもりにしない。 |
| feature | countsは全4値が非0かつ各row和<=32768、count feature=旧ln_count。CTS feature=旧ln_cts(cts*2048)。active count featureは0..44655667077、active CTS featureは-62517933908..0、全inactive feature0を新domainとする。observeはprefix/child/weight→q→p→featureの順で検査。scores/CDFはobserveで未使用のまま。 |
| score/q | pool weight[0,2Q]、score=Σ(weight_Q21*feature_Q32)/Q、符号付きゼロ方向丸め。旧exp_neg(max_score-score)のmass_Q32をHamiltonでQへ配分。q active0は合法、inactive0、全和Q。 |
| p | smooth mass=4095*prefix*q+Q、通常HamiltonでQへ配分。p>=floor(Q/(4096*prefix))、最終CDF32768へ通常Hamiltonで配分、全active frequency>=2。 |
| pool normalization domain | active input mass<=16381*Q、inactive0、total>0。qの旧exp mass<=Q_LOGもこのdomain内。candidate/oracle双方が同じdomainを算術より先に検査する。未知巨大massを黙ってsigned/unsigned64へ狭めない。 |
| 学習 | mass=4095*prefix*q[child]、factor=floor(mass*Q/(mass+Q))。expected=Σ(q*feature)/Q、gradient=factor*(observed_feature-expected)/Q、いずれも順にゼロ方向丸め。delta=gradient/524288をその後計算、next=clamp(weight+delta,0,2Q)。factor0は合法。 |
| model | 初期pool weight[Q/4,Q/4,Q/4,Q/4,0]はQ_PROBで作る。Math Qを初期weightへ誤接続しない。serial、全準備後CTS commit、base/pool/auditの非fallible commit順は維持。 |

正常域ではmixture<=2^42、posterior numerator<=2^63、KT積<2^44、score積和<2^61、expected/gradient積和<2^57、pool正規化積<2^56、CDF積<=2^36。signed除算を負数の算術shiftへ変えない。candidateはchecked u64/i64を使い、新Kernel massはu64で保持できる。Snapshotのvisible/certified完全照合、current guard優先、必要時の全derived再predict、CAPと全prepare後commitを維持する。Node raw/weight型・path履歴・全9段の意味は維持。

## 独立oracle・失敗計画・E2E

oracle.rsは同じ新policyをchecked u128/i128で独立に記述する。candidateのKT/normalize/mixture/posterior/pool更新をoracleへ呼ばせない。旧Q32 primitiveを新Q21 oracleとしない。凍結Math/LUTの共有だけは許容し、candidate/oracleの変換・signed丸め・feature domainを別に検査する。reference CTSは全current snapshotを再predict照合し、candidateのseal高速経路と独立に保つ。

- prefix1..4、全heavy位置、均等tie、raw Q-2/Q-1/Q/CAP、inactive rawを含む全和CAP。分析goldenでKT各active1と総和Q・tieを固定し、単純Q差替えの反例を必須にする。
- after1/Q-1/Q/Q+1/CAP、0/CAP+1、weight0/Q、depth0..8、全child、複合不正のErr優先。candidate/oracleの全Result配列・posterior/alpha/nextを直接比較。
- CTS全公開Snapshotの各field、全nodes raw/weights・history・class observationsを直接比較。pure predict、改変KT/mixed/mass、stale、foreign、同stateへrebasedされた合法Snapshot、leaf/非leaf不正、node/class CAP、各拒否前後の全state、prepare atomicity。dtypeが異なるmassはexact変換で全要素照合し、digestのみで代用しない。
- pool count1/32768のMath境界、CTS1/Q、weight0/2Q、score差・cutoff、signed丸め、q0/factor0、feature domain上下端と±1/inactive不正、prefix/child/weights/q/p複合不正。新domain拒否は旧Prediction全入力との互換とは言わない。
- selfcheckは新depth[0,1,2,4,5,8]。各depthで旧14正常・33malformed・4short・model拒否/atomic CAPを移植し、旧KHQCID01拒否も追加。全plain byte、canonical全frame、encode/decode全Proof14field（CDF to_bits）を直接比較。旧Q32 codec selfcheckも旧Math/pool/CTSだけへ接続して保持する。
- 件数・fixture入力・期待結果はFAILURE_PLANへ事前保存、runnerが不足/追加/解析失敗を拒否する。失敗は最大4KiBの最小入力/reasonをreportへ残す。unit test、raw trace、input/plain/frame diskコピーは追加しない。

## 条件付き1周ABBA・固定gate

fixed input `build/khc-current-source-native-solid-20260923-group/all.group` は2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を1read。既存基点Aはdepth5/旧pool/旧Math/旧updateの凍結数値/timer本文を維持し、module aliasだけ別old_pool/baseline CTSへ結線。Bは上記新形式だけ。従来3未採用最適化をA/Bへ入れない。

全E2E合格後、同binaryでold A/new B/new B/old Aをwarmupなし1周だけ行う。最初のBのsizeが483599Bを越えた場合はそのBの全plain/Proof確認まで保存し、後続B/Aの速度比較を行わずsize-rejectedとする。失敗をpassedと表現しない。新/旧のframe/weights/digest/CDF数値一致は要求しない。各実装自身のencode/decode全Proof・全plain、同実装2回目との全frame・Proofを直接比較し、旧Aの固定478750Bと旧CRC/statsを再確認する。grammar/counts/classes/plain CRCの不変条件はBでも保持する。

成功ABBAの新baseline候補採用にはsize<=483599BかつB平均encode<A平均encodeとB平均decode<A平均decodeの両方が必要。1周は診断で統計的優越の証明ではない。正式codec median<574.5624ms、machine CPU<=15%、独立holdout/categories、4native、製品/API統合は別の未達gate。評価条件を緩めず、好都合な時間を得る反復/別binary比較で採用しない。

全frame比較はRAM内のみ、cloneせず2実装のreferenceを各1枚move保持し、2回目比較後drop。live current+references最大3枚（旧478750+新2*483599<=1445948B）、最終0。これは全process RAM peakではない。計時body内にJSON/Proof比較/新log/生traceを入れない。

## 実行・identity・容量

verify-q21.ps1は非Execute時にparser/静的graph/identity/basis/予算を確認し、fresh outputを作らない。新source/Math/root graph接続を列挙し、old/new相互の誤aliasとoracle共有を検査する。旧149 identities+本契約/Alpha RESULT/feasibility+新11fileの163件をbefore/after/liveでSHA/bytes/UTCticks照合。本契約SHAは保存後にrunnerへ固定する。数値本文とtimer差分を親が確認し、独立readonlyレビュー回収・worker所有返却後に親だけがExecuteする。

専用PowerShell7.6.5/SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139、rustc1.98.1/SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。edition2024/frame_audit/primitive_audit/opt-level2/overflow-checks=yes/panic=abort/debuginfo0/link /DEBUG:NONE。rustfmtはstdoutだけ、code compile1、各固定CLI1だけ、失敗時は証拠保存して理由を返す。再実行はしない。

出力は `build/khc-quaternary-cts-mixed-q21-20261003/` のEXE/report2件のみ、合計8MiB/EXE1MiB/report512KiB、見積り1.5MiB以下。事前/事後disk-budgetとfree>=5GiB+8MiB、各write前に上限確認、timeoutに所有processを終了して回収する。reportは成功/拒否/失敗を区別し、実際のargv/exit schemaとCLI件数を保存。codec CLIはcompare/selfcheck-old/selfcheck-new/abbaの4種類、各1回。compile/version/Rustfmtは別記録。Cargo target/table/asm/PDBや既存artifactコピーは作らない。成果・再現証拠は保持し、用途済み一時物だけ清掃。ドライブ空き変動と本生成bytesを混同しない。
