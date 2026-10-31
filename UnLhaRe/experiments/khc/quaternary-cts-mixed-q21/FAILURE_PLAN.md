# mixed Q21 private codec: 実装前の失敗計画

作成日: 2026-10-03。これは新11fileのうち最初の文書であり、コード、compile、候補CLI、Execute、benchmarkはまだ作成・実行していない。ここで固定する件数は後段standalone E2Eの期待値で、実測成功件数ではない。unit testは追加しない。

正本: `../QUATERNARY_CTS_MIXED_Q21_CONTRACT_20261003.md` SHA256 `E2268BEDAA246D76FE8227DBA664627AA6AAC498A604F04C51FE5C8CF4FA3C54`（全文照合済み）。実現性: `../QUATERNARY_CTS_MIXED_Q21_FEASIBILITY_20261003.md` SHA256 `44FB4B26E1F40DFD376E568DBD17F65878885ED322B74A0AA9ED49EB1FD39DF2`。固定契約、旧結果、旧source、既存EXE/report、dirty changesは変更しない。

## 1. 失敗の全分類と固定policy

| 失敗 | 検出する入力・観測 | 固定する期待 |
| --- | --- | --- |
| Qだけ変更してKTが0になる | raw=[Q-1,0,0,0], prefix2 | reserve1 KT=[Q-1,1,0,0]。単純Hamiltonは[Q,0,0,0]となりvector拒否 |
| alphaがCAP内で0になる | after=Q/Q+1/CAP | alpha=1、更新成功。after=Q-1でもalpha=1。depth0はswitchを呼ばない |
| 単位混在 | CTS1/Q、pool初期weight、feature/score/gradient/delta | Q_PROB=2097152、Q_LOG=4294967296、CTS*2048、delta=/524288 |
| KTとmixtureの配分混同 | 均等tie、heavy全位置、weight0/Q | KTのみ各active1予約。mixture/p/q/CDFは通常Hamilton |
| rawのinactiveをCAP検査から外す | inactive raw=CAP/CAP+1 | 全4raw和でCAP、inactive raw自体は合法 |
| unsigned/signed64へ無検査で狭める | oversized normalization mass、feature=i64::MIN/MAX | 算術前に新domain拒否。oracleも同domain拒否 |
| 負数をshiftで丸める/丸め順を変える | 小さな負gradient、段階ごとの独立golden | /はゼロ方向、expected→gradient→deltaの順 |
| q0/factor0を拒否する | sparse q、observed q=0 | q0合法、factor0/gradient0/delta0/next不変、pとCDFは正値 |
| sealを信頼して可視改変を取りこぼす | KT/mixed/massを含む全field改変 | certifiedとの完全比較。異なる場合は現在snapshot全derivedを再predict |
| token出自だけで拒否/受理する | foreign、同state foreign、rebased合法token | 現在の全可視fieldと一致するかで判定。出自IDは追加しない |
| stale検査がcurrent guardを隠す | stale+class CAP、leaf不正、nonleaf不正、raw超過 | 旧current guardのErr優先を維持 |
| 部分commit | 深いpath最後でnode CAP、modelのCTS commit失敗 | 全nodes/history/observations/base/pool/serial/auditが拒否前後で不変 |
| 旧形式の誤受理 | KHQCID01/KHQCIP01/未知magic | headerの最初でbad frame magic/header |
| header/depth/CRC/packed/range/BWT/escape破損 | 下記の全forge | 指定した正確なErr、panicなし、plain成功を報告しない |
| Proof一部比較/JSON丸め | encode/decode/reencode全Proof | 全14fieldを直接比較、CDFはto_bits。全plain、全frame直接比較 |
| 旧Q32を新oracleへ誤接続 | root/module graph | 新oracleは独立checked u128/i128。凍結Math/LUT以外の数値共有は禁止 |
| Bの数値へ旧固定値を誤適用 | 新depth8 selfcheck、新depth5 fixed input | 新旧frame/weights/digest/CDF同値を要求しない。grammar不変と旧A数値検査を分ける |
| 数/CLI/parser/identity/予算不足をpassedにする | 固定counter、163identities、CLI4種類、timeout | 不足・追加・schema解析失敗はfailed。size-rejectedはpassedと区別 |

Q=Q_PROB、CAP=3825340、classes6、levels9、depth0..8。active CTS/pは1..Q、inactive0、和Q。qのみactive0合法。pool weight0..2Q。feature: count行0..44655667077、CTS行-62517933908..0、inactive全0。pool normalization active mass<=16381Q、inactive0、total>0。countsはinactiveを含め全4値非0かつrow和<=32768。

候補のCTS/kernel massはu64、oracleはu128。正常上限はmixture2^42、posterior分子2^63、KT積<2^44、score積和<2^61、expected/gradient積和<2^57、pool積<2^56、CDF積<=2^36。checked_mul/add/sub/divとexact conversionを用いる。checked_shlは上位bit喪失を検査しないためCTS変換へ使わない。

## 2. 独立oracle、直接比較、拒否priority

`oracle.rs`は新KT reserve1、通常Hamilton、mixture、posterior、predict_kernel/update_kernel、pool predict/observe、reference Ctsをchecked u128/i128で別に記述する。candidate関数、旧Q32 primitive、candidate normalization/domain helperを呼ばない。定数は各moduleに明示しgoldenで整合を検査する。Math/LUT instanceのみ共有可。candidate/oracleともdomain guardを同じ順で算術前に実行し、巨大入力をoracleだけ成功させない。Err文字列は各moduleに独立に置き、比較側の期待値と照合する。

全Resultを比較する。成功時はKT/mixture全4値とmass全4値、kernel全9x4のkt/mixed/massesとdepth、posterior/alpha/next全3値、update全9weightを比較する。pool Predictionはprefix/weights/features/scores/q/p/frequencies/cumulative全field、Updateはfactor/expected/gradient/delta/next全fieldを比較する。candidate massは`u128::from(candidate)`でexact比較し、oracleからu64へのas castやdigestだけで代用しない。

Snapshot比較はclass、prefix、ids[9]、history、observations、raw[9][4]、weights[9]、kernel.depth、kernel.kt[9][4]、kernel.mixed[9][4]、kernel.masses[9][4]の全要素。depthを越える未使用levelとleaf massesの0も比較する。candidateのvisible/certifiedは同module内監査関数で完全比較できるようにするが、oracleにseal経路は設けない。reference Cts.observeは毎回current predict全Snapshotを比較する。

全Cts state比較はdepth/node_count/nodes.len一致の後、全classの全nodeのraw[4]/weightを順番に直接比較し、history[6]/observations[6]も比較する。全node（選択path以外とinactive classを含む）を省略しない。拒否前は各実装の全stateをRAMに保存し、拒否後は各実装自身とbeforeの全fieldを直接比較、その後candidate/oracle間も全state直接比較する。大きいdepthはfixtureを逐次処理しbeforeを解放、raw traceを保存しない。

| 操作 | 拒否priority（左から先行） |
| --- | --- |
| vector/KT/normalize | invalid prefix → categorical形/domainまたは全raw CAP/mass domain → total → 算術/Hamilton → 結果vector |
| mixture | weight outside Q → own vector（prefix含む）→ child vector → mass/Hamilton → 正値vector |
| posterior_switch | weight/own/rawmass0/after範囲によるinvalid switch input → denominator outside mixture → posterior/alpha/next |
| predict_kernel | prefix → depth/leaf → level昇順のweight、全4raw CAP、KT → 下からmixture |
| update_kernel | prefix → child/depth/after/leafのinvalid kernel update → level0からswitch。depth0の未使用KT/mixed/mass/nonleaf weightは読まない |
| Cts.predict | prefix → class → class observation cap → current leaf → level昇順weight/raw CAP → derived |
| Cts.observe | prefix → class/child → snapshot/current class update cap → current leaf → level昇順weight/raw CAP → structural/current Snapshot → seal全比較/必要時再predict → update_kernel → level昇順node update cap/prepare → commit |
| pool.predict | prefix/weights → CTS vector → count全row domain → Math/変換 → scores → exp/Hamilton q → smoothing p → CDF |
| pool.observe | prefix/child/weights → q shape/和（checked）→ p vector → feature active domain/inactive0 → 学習。scores/frequencies/cumulativeは未使用のまま |
| model.observe | serial/component/child/prefix一致 → base row → pool weights → pool observe → 全counts prepare → serial/audit prepare → CTS observe → 非fallible base/pool/serial/audit commit |
| frame.decode | len40/magic → depth → field bounds → transformed payload bound → packed header length → header CRC → packed canonical/count → payload CRC → range/grammar → inverse BWT → plain CRC |

新domain Errはplanで`pool mass domain`、`pool feature domain`と固定する。旧の`invalid prefix`、`invalid categorical vector`、`vector sum differs from Q`、`raw observation cap`、`weight outside Q`、`invalid switch input`、`posterior denominator outside mixture`、`invalid kernel depth/leaf`、`kernel weight`、`invalid kernel update`、`invalid class`、`class observation cap`、`invalid observation`、`class update cap`、`stale or modified snapshot`、`node update cap`、`pool prefix/weight`、`pool count row`、`pool observed child/weights`、`pool q snapshot`を維持する。prefix=0で巨大mass/不正featureを併せてもprefix系が先行する。

## 3. primitive/kernel固定loopと件数

各caseはfixture ID・loop index・expected Resultを持つ。重複値になったdenominator/weightもloopの1caseとして計数し、dedupしない。最初のmismatchで停止するためfailed reportは完了済みcountと予定countを分ける。

列挙表のdepth0..8、k1..4、class0..5、row/weight-index0..4、level0..7、round0..1は両端を含む。child/hの0..k、inactiveのk..4はRust半開区間（child/hはk未満、inactiveは4未満）。全fixtureは記載の基点から独立に生成し、改変を次caseへ引き継がない。配列値を和Q±1へ変えるcaseはBALの最大active要素を±1し、形Errが先行するprefix1/Q+1を明示的に区別する。

| loop ID | deterministic fixture/loop | 予定件数と期待 |
| --- | --- | --- |
| V-valid | k=1..4、Qを均等Hamilton配分しinactive0 | 4成功 |
| V-invalid | k=1..4 × active0/Q+1/全和Q-1/全和Q+1（active0/Q+1は形Err、和だけずらすcaseはprefix1のQ+1のみ形Err） | 16拒否、caseごとの形/和優先 |
| KT-heavy | k=1..4、h=0..k、r=[Q-2,Q-1,Q,CAP]、raw[h]=r/他0 | 40成功、全active>=1、inactive0、和Q |
| KT-tie | k=1..4、全4rawをt=[0,1,Q/8]にする | 12成功、余りtie child昇順 |
| KT-inactive | k=1..3、h=k..4、raw[h]=[CAP,CAP+1]、他0 | 12: 6成功/6 raw observation cap |
| KT-allraw | k=1..4、raw=[CAP-3,1,1,1]、[CAP-2,1,1,1] | 8: 4成功/4 raw observation cap |
| KT-prefix | k=[0,5,usize::MAX]、raw=[u32::MAX;4] | 3 invalid prefix。KT計75 |
| MIX-valid | k=1..4、h=0..k、w=[0,1,Q/2,Q-1,Q]。own均等、child[h]=Q-k+1/他active1 | 50成功、mass和Q²、w0/Q endpoint |
| MIX-invalid | k2: w=Q+1/u64::MAX + prefix0（2）；own/childそれぞれactive0、inactive1、和Q-1（6） | 8拒否。MIX計58 |
| SWITCH-valid | after=[1,Q-1,Q,Q+1,CAP] × w=[0,Q/2,Q] × own=[1,Q/2,Q] × denom=[lo,lo+(Q²-lo)/2,Q²], lo=max(1,w*own) | 135成功、全tuple直接比較 |
| SWITCH-invalid | 有効w=Q/2,own=Q/2を元にafter0/CAP+1/u32MAX、wQ+1、own0/Q+1、rawmass0、rawmass=ownmass-1、rawmass=Q²+1 | 9拒否、前7 invalid switch input/後2 denominator outside mixture |
| SWITCH-priority | wQ+1+rawmassQ²+1、own0+after0、rawmass0+afterCAP+1 | 3 invalid switch input。SWITCH計147 |
| K-normal | depth0..8 × k1..4 × child0..k × after=[1,Q-1,Q,Q+1,CAP] × w=[0,Q/2,Q]。raw[l][j]=(l+3)*(j+5)、leafw=Q/2 | 1350成功 |
| K-entry | 旧Alpha entry loopそのまま: depth[0,5,8]でk/child/after0,CAP+1,u32MAX、prefix[0,5,max]×after[0,1,CAP+1]、child=k×after、leafQ/2±1×after[1,CAP]。depth[9,max]×k×after[0,1,CAP+1] | 225拒否、prefix優先、他invalid kernel update |
| K-switch | depth8、after5値 × level0..7 × tamper6（wQ+1、own0、ownQ+1、mass0、ownmass-1、Q²+1） | 240拒否、先4 invalid switch input/後2 denominator outside mixture |
| K-priority | after5値 × (first,second,invalid_first)=[(0,7,true),(0,7,false),(2,5,false),(2,5,true)] | 20拒否、最初のlevelのErr |
| K-empty | depth0 × k/全child × after5値、KT/mixed/mass全て不正・他levelwQ+1、leafのみQ/2 | 50成功、全nextQ/2。K計1885 |

独立analytic goldenは次の7件を別counterで固定する（上記caseと重複してもgolden counterは別）。

1. naive KT raw[Q-1,0,0,0]/prefix2 → [Q,0,0,0]、新reserve1 → [Q-1,1,0,0]。
2. raw全0/prefix3 → [699051,699051,699050,0]。
3. raw[CAP,0,0,0]/prefix4 → [2097148,2,1,1]。
4. after=Qでnaive alpha0、新alpha1。w=Q,own=Q,rawmass=Q² → posteriorQ,nextQ-1。
5. after=CAP、w0/own1/rawmass1 → posterior0,alpha1,next1。
6. prefix1ではraw合法全域のKT=Q。mixture w0/Q、own=child=[Q,0,0,0] → mixed同値、mass[Q²,0,0,0]。
7. after1ではalphaQ/2,retained0、posterior0/Qの両endpointともnextQ/2。

## 4. Cts sealed/reference全state固定loop

| loop ID | fixture/手順 | 予定件数と期待 |
| --- | --- | --- |
| CTS-constructor | depth0..8、新/referenceのnodes=6*Σ(4^l)、raw全0、w全Q/2、history/observations全0。depth9/max拒否 | 9成功/2拒否 |
| CTS-stream | depth0..8 × class0..5 × k1..4 =216独立pair。各pair round0..1でchild0..k昇順。各step predict2回→全Snapshot一致・両state不変→observe→全state一致 | 1080成功observe、1080 pure predict。Snapshot比較2160、初期/予測後/commit後state比較2376 |
| CTS-token | 各216pairの最後current tokenからprefix0、child=k、最初のstale、kt[0][0]^1、mixed[0][0]^1、masses[0][0]^1、ids[0]^1、raw[0][0]^1、weights[0]^1、kernel.depth=9 | 2160拒否、prefix/childの他はstale or modified snapshot。各拒否両before/after全state不変 |
| CTS-foreign | 216pairそれぞれ別instanceを1step多く進め、そのtokenを元pairへ渡す | 216 stale or modified snapshot、全state不変 |
| CTS-same-state | 216pairそれぞれ同stateの別instance由来tokenを元pairへ渡す | 216成功、全Snapshot/全state一致。出自だけでは拒否しない |
| CTS-rebased | 216pairそれぞれstale tokenの全visible fieldを現在合法snapshotへ置換（candidate certifiedは旧のまま）してobserve | 216成功、candidateが再predictしreferenceと一致。certifiedの公開APIは作らない |
| CTS-CAP | depth0..8 × class0..5、全path raw[CAP-1,0,0,0]、obsCAP-1、k4/child0 → successCAP。次observeはclass update cap。obsCAP+1 predictはclass observation cap | 54成功/108拒否 |
| CTS-node-atomic | 同54pair、classobs0、path末尾raw[CAP,0,0,0]、他pathraw0、k4 | 54 node update cap。先行prepare済み全nodeも変化なし |
| CTS-current | 同54pair、current葉wQ/2+1 + stale→invalid kernel depth/leaf；currentraw[CAP+1,0,0,0]+stale→raw observation cap；currentclassCAP+stale→class update cap；snapshotobsCAP+badleaf→class update cap | 216拒否、current guard優先 |
| CTS-nonleaf | depth1..8 × class0..5、level0 wQ+1+stale、raw超過も併置 | 48 kernel weight、全state不変 |
| CTS-inactive-raw | 同54pair、k2、path全raw[0,0,CAP-1,0]、obs0→predict合法→child0 updateで全node総和CAP | 54成功、inactive raw保持。次は54 node update cap |
| CTS-level-priority | depth1..8 × class0..5、rootraw超過+leafw不正、rootw不正+後段raw超過 | 96拒否: 前case leaf、後case kernel weight |
| CTS-class-prefix | depth0..8 × (prefix0/class6、prefix4/class6、prefix4/child4) | 27拒否: invalid prefix / invalid class / invalid observation |

全CTS observe成功=1080+216+216+54+54=1620、predict/observe拒否=2160+216+108+54+216+48+54+96+27=2979（constructor拒否2は別）。foreign/same-state/rebasedは元pairを別々にcloneし、別loopのstate汚染を防ぐ。全Snapshot field比較はCTS-streamの2160に加え各token fixtureのcurrent/foreign/rebasedを直接比較するが、stream counterには混ぜない。allstate counterはloop別に記録し、拒否2979件は各実装のbefore/after全比較2979ずつと前後candidate/reference比較5958を必須にする。predict拒否にも同じ全state不変検査を行う。

## 5. pool/Math/learning固定loop

`BAL(k)`=Q通常Hamilton均等、`SPIKE(k,h)`=hにQ-k+1/他active1。counts shapesは全row[1;4]と、全rowで[32765,1,1,1]をh0..3へrotateした4形（計5）。count32768はMath単独境界では合法だが、pool row[32768,1,1,1]は和超過として拒否する。

weights shapesは全0、全2Q、初期[Q/4;4]+CTS0、[2Q,0,0,0,0]、[0,0,0,0,2Q]（計5）。初期値がMath Q/4を使っていないことを明示検査する。

| loop ID | fixture/loop | 予定件数と期待 |
| --- | --- | --- |
| POOL-predict | k1..4 × CTS(BAL + 全h SPIKE) × counts5 × weights5 | 350成功、全Prediction比較 |
| POOL-learn | 上記各Predictionで全child0..kへobserve（stateなし） | 1000成功、全Update比較 |
| POOL-count-bad | k1..4 × row0..3 × row[0,1,1,1]/[32768,1,1,1] | 32 pool count row |
| POOL-cts-bad | k1..4 × cts active0/Q+1/和Q-1/和Q+1 | 16 CTS vector拒否（prefix1はactive0/Q+1/和Q+1のみshape、和Q-1はvector sum differs from Q） |
| POOL-weight-bad | k1..4 × feature weight index0..4 × 2Q+1/u64MAX | 40 pool prefix/weight |
| POOL-prefix-bad | prefix0/5/max、weightsu64MAX・cts0・counts0併置 | 3 pool prefix/weight。predict拒否計91 |
| POOL-normalize | k1..4 × mass全active16381Q / 一active16381Q他0 / 全active1、inactive0 | 12成功（q0は合法） |
| POOL-normalize-bad | 各activeに16381Q+1（Σk=10）、各inactiveに1（Σ(4-k)=6）、全mass0×k4、全active u64MAX×k4、prefix0/5/max | 27拒否、domain/zero total/prefix優先。normalize計39。u64MAXはtotal算術前のdomain拒否、oracleもu128 exact入力で同拒否 |
| POOL-smooth-prefix | prefix0/5/max、q=[u64MAX;4]をsmoothへ直接渡す | 3 invalid prefix、算術・配列アクセス前に拒否。smooth_prefix_guard_cases=3として別counter |
| POOL-score | k1..4 × 合法feature pattern4（全0、child0のcount4行hi/他child CTSlo、その反転、child偶数のcount4行1/奇数CTS行-1）× score専用weights5形。最初4形はpredictと同じ、最後だけ[0,0,0,0,1]。inactivefeature0 | 80成功、全scores/差/exp mass/q/p/CDFを比較。score差0..482281204432を検査、cutoffを跨ぐendpointを含む。pattern3/最後weight/CTS=-1のchildはscore=0（-1/Qをゼロ方向へ丸める） |
| POOL-feature | k1..4 × active child0..k × feature row0..4 × [lo,hi,lo-1,hi+1]。q=p=BAL、weights初期、他feature0 | 200: 100成功/100 pool feature domain |
| POOL-feature-inactive | k1..3 × inactivechildk..4 × row0..4、feature=1 | 30 pool feature domain |
| POOL-feature-huge | k1..4 × activechild0..k × row0..4 × i64MIN/i64MAX | 100 pool feature domain、oracleも算術前拒否 |
| POOL-q0 | k2..4 × heavyh0..k × observedchild!=h、q=SPIKE0（hQ/他0）、p=smooth(q)、feature=count row[1,0,...]合法、CTS row0 | 20成功、factor0/gradient0/delta0/next=weights |
| POOL-observe-priority | 下記20fixture | 20: 19拒否/1成功、正確なpriority |
| MATH-connect | ln_count1/32768、ln_cts(1*2048)/(Q*2048)、CTS vector0/Q+1 | 6: 前4成功/後2vector拒否。ln_count1=0、ln_cts(Q*2048)=0 |
| EXP-domain | d=[0,1,EXP_CUTOFF-1,EXP_CUTOFF,EXP_CUTOFF+1,128Q_LOG,-1,128Q_LOG+1] | 8: 6成功/2 exp domain、mass0 cutoffを含む |
| SIGNED-golden | 下記4fixture | 4成功、段階別expected/factor/gradient/delta/nextの独立golden |

observe-priority20fixtureはprefix2、child0、q=p=BAL、feature全0/weights初期を基点とする。

1..3 prefix=0/5/max + childmax/weightsmax/q0/p0/featuremax → pool observed child/weights。
4 child=prefix + q0/p0/featuremax、5 weight=2Q+1 + q0/p0/featuremax → 同Err。
6 q activeQ+1、7 q和Q-1、8 q和Q+1、9 q inactive1、10 q=[u64MAX;4]（checked和に先立つshape拒否）→ pool q snapshot。
11 q不正+p不正+feature不正 → pool q snapshot。
12 p active0、13 pQ+1、14 p inactive1 → invalid categorical vector。
15 p和Q-1、16 p和Q+1 → vector sum differs from Q。
17 p不正+feature不正 → pのErr。
18 active countfeature=-1、19 inactivefeature=1 → pool feature domain。
20 scores=[i64MAX;4]、frequencies=[u32MAX;4]、cumulative=[u32MAX;5]のみ改変 → 成功。observeはこれらを使わずUpdateは基点と完全一致。

独立pool golden:

- sparse q=[Q,0,0,0]/prefix4 → p=[2096768,128,128,128]、CDF frequency=[32762,2,2,2]、cumulative=[0,32762,32764,32766,32768]（golden1件）。
- SIGNED-golden1: prefix2、q=p=[Q/2,Q/2,0,0]、countfeature行0=[1048577,0,0,0]、他feature0、child1 → expected[0]=524288、factor=2096640、gradient[0]=-524160、delta[0]=0、next=weights。算術shiftならdelta=-1となり誤り。
- SIGNED-golden2: 同fixture child0 → expected524288、factor2096640、gradient524160、delta0。
- SIGNED-golden3: 行0feature=[1,0,0,0]、child1 → expected0、gradient0、delta0（積和を先にshiftしない）。
- SIGNED-golden4: CTS行feature=[-1,0,0,0]、child0 → expected0、gradient0、delta0（expectedの負1/2はゼロ）。

score差はPOOL-scoreの合法domain featureをRAM生成し、predictのscore→exp→q/p/CDF bodyをcandidate自身のprimitive_audit入口から呼んで比較する。oracleは別bodyを使う。count hiとCTS loの新domain端点を算術前に検査し、各candidate/oracle全scoresとMath.exp_neg入力を直接比較する。Math cutoffは上記8点で独立比較する。学習順序の中間値はUpdate全fieldに含め、最終weightだけの一致にしない。q0のrare側にもfeature domainは適用し、factor0を理由に検査を飛ばさない。

保存順の補足: 失敗分類と数値policyはコード前に保存した。POOL-scoreの最後weight/負小数goldenのexact具体化はcandidate/oracle score body作成後、comparison fixture作成前に親が確認・許可した。80件、policy、scoreのchecked_div bodyは不変。POOL-predict350/learn1000のweights5形は変更しない。全exact fixtureが数値body作成前だったとは扱わない。

保存順の補足2: 公開smoothのprefix guard不足を親のreadonly確認が検出したため、candidate/oracle numeric bodyと既存comparison fixture作成後に、親が同じprefix失敗分類の是正を許可した。この追記を保存してから両smoothの独立guardと3件の直接fixtureを追加する。normalize39/score80等の既存件数は不変。

保存順の補足3（Execute前の独立検証に対する是正計画）: comparison/selfcheckの失敗時に完了済み件数が消え、refusal・malformed・shortの失敗reasonに最小recipeが不足していた。次の記録処理だけを親が補強する。数値policy、正常JSON、成功件数、forge、期待Err、timer本文は変えず、compile/候補CLIはまだ0回。

| 既存の失敗分類 | 是正後に保存する証拠 |
| --- | --- |
| primitive/kernel/pool/CTSの最初の失敗 | compare failed JSONに全loopの予定件数と完了したResult比較件数、phase、直近fixture、pure/Snapshot/state/成功/拒否counter。差のreasonはrecipeを先頭へ置き、Resultの最初のDebug byte index、Snapshot/stateでは最初のfield/node/childを示す。拒否前後は各実装を不変な他方のbefore stateとも比較し、両方が同じように変化しても検出する |
| codec正常/malformed/short/model groupの最初の失敗 | selfcheck failed JSONに完了したdepth records、失敗depth、phase、fixture name/index・生成recipe・seed、予定/完了したnormal/plain/canonical/Proof/malformed/short件数。malformedはexpected/actual Err・frame長・先頭64byte以内、shortはtruncate長をreasonへ残す。凍結model拒否helper内の途中assertion数は観測できないため、失敗時に16件完了と推定せず、単一aggregate groupの予定1/完了0を記録する |
| 失敗JSON解析・保存 | 非zero終了のJSONもstderrとともにreportへ保存してから拒否する。正常終了のstderr禁止は維持。最初のreasonだけをUTF-8 JSON最大4096byteに抑え、truncated/original_bytesを保存。panic/child timeoutでは完了件数を推定せず、既存のbounded stderr/exit/statusを失敗として保持する |

これは既に固定した失敗分類の記録是正であり、新しい数値fixtureやunit testの追加ではない。独立再確認とnonExecuteを終えるまでExecuteしない。

## 6. 新旧codec standalone selfcheck

新depthは[0,1,2,4,5,8]の6件。旧Q32 selfcheckは凍結既存[4,5,6,7,8]の5件を保持する。旧は旧Math/旧pool/旧CTSのみへ接続し、新oracleを旧検証へ入れない。旧selfcheckは新旧frame一致の根拠ではない。

各depth正常14fixtureはRAM生成:

| fixture | 正確なinput |
| --- | --- |
| empty | [] |
| constant0-1/2/255/256/257/383/384/16639/16640 | 指定n個の0（9件） |
| all256 | i=0..1024のi%256 byte |
| sparse-high255 | i=0..64の[0,3,127,255][i%4] |
| lcg4096 | seed0x6d2b79f5、各byte前seed=seed*1664525+1013904223（wrapping u32）、seed>>24、4096byte |
| text128 | UTF-8 ASCII `Kagayoi private integer CTS frame.\n` を128反復 |

各fixture encode→decode全plain byte→再encode全frame byte。3つのProof（初encode、decode、再encode）の全14field（runs,primary,alphabet,payload,plain_crc,payload_crc,rank,length,escape,grammar,base_pool,branches[2],classes[6],cdf_bits）を直接比較し、14field省略を拒否。CDFはto_bits。初回/再encode statsも自身の実装内で比較する。CRC32 `123456789`=0xcbf43926を各depth1回確認する。

新正常84、plain84、canonical84、encode/decode Proof84・repeat Proof84。旧正常70、plain70、canonical70、encode/decode Proof70・repeat Proof70。Proof比較を追加するが旧数値/timer bodyを変えない。

各depthの旧33malformedは同forge recipeを移植し、新のみold_q32_magicを1件追加（34/depth、新204、旧165）。`E`は当該実装のempty frame、`set`はu32LE field、`repair`はheader CRCのみ再計算、`replace_payload`は長さ/payload CRC/header CRCを修復。header配置はmagic0..7、length8、primary12、alphabet16、payload20、plainCRC24、payloadCRC28、headerCRC32、depth36、metadata40、empty payload73。

| name | RAM fixture（変更前はE） | expected Err |
| --- | --- | --- |
| short_header | truncate31 | bad frame magic/header |
| old_magic | magic=KHQCIP01 | bad frame magic/header |
| old_q32_magic（新のみ） | magic=KHQCID01 | bad frame magic/header |
| bad_magic | byte0 xor1 | bad frame magic/header |
| input_length | set8=MAX_INPUT+1 | frame fields outside bounds |
| primary_field | set12=1 | frame fields outside bounds |
| alphabet_zero/over | set16=0/258 | frame fields outside bounds |
| payload_short/quota | set20=4/MAX_PAYLOAD+1 | frame fields outside bounds |
| payload_derived_bound | set20=39 | payload exceeds transformed bound |
| header_crc | byte32 xor1 | header CRC mismatch |
| payload_crc | byte73 xor1 | payload CRC mismatch |
| plain_crc | set24=1、repair | plain length/CRC mismatch |
| metadata_padding | byte72 or2、repair | packed alphabet high bitmap padding nonzero |
| metadata_sentinel | byte40=2、repair | packed alphabet sentinel 0 missing |
| metadata_width | insert73=0、repair | packed alphabet rank byte width not canonical |
| metadata_rank | frame(n1,primary0,order[0,1],payload[0;5])、byte73=2、repair | packed alphabet rank outside factorial |
| range_prefix | replace_payload[1,0,0,0,0] | invalid range prefix |
| range_gap | replace_payload[0,255,255,255,255] | range rounding gap |
| range_truncated | encode constant0-16640、payload先頭5byteのみへreplace | truncated range stream |
| range_trailing | replace_payload[0;6] | trailing range bytes |
| range_termination | replace_payload[0,0,0,0,1] | noncanonical range termination |
| sentinel_count | scripted(n2,order[0],rank0/token1/noescape) | sentinel count |
| primary_sentinel | encode_payload last[0,1]、frame(n2,primary1) | invalid primary sentinel |
| lf_cycle | 同payload、frame(n2,primary0) | LF cycle inconsistent |
| active_early | scripted(n2,order[0],rank0/token0/noescape) | active list exhausted before declared length |
| active_remaining | scripted(n1,order[1,0],rank1/token0/noescape) | active list not empty at end |
| escape_noncanonical | scripted(n256,order[0],rank0/token255/escape[128,0]) | noncanonical length escape |
| escape_fourbytes | 同、escape[128;4] | length escape exceeds four bytes |
| escape_remaining | 同、escape[1] | run length outside remaining bound |
| unsupported_depth9/max | set36=9/u32MAX、set8=MAX_INPUT+1、byte32 xor1 | unsupported CTS depth（他不正より先） |
| depth_crc | set36=depth8なら0/他なら8、CRC未修復 | header CRC mismatch |

別short4fixtureは各depth Eをtruncate36/37/38/39、全てbad frame magic/header。新24/旧20。magic以外未知policyをdepthだけで識別しない。

各depthのmodel拒否は旧14 named/16 assertions/1 CAP exactを移植する。6つのpredict不正: prefix0、prefix5、component2、context9、node256、symbol257。observe child4、stale branch、modified CTS mixed、row idMAX、poolweight2Q+1、zero count、row和32771、classCAPでobserve、classCAP+1でpredict、class内nodeCAPでobserveの計16 assertions。CAP-1からCAPへの合法成功は別1件。全拒否で全base values/totals、pool weights、CTS全raw/weights/history/observations、serial、audit branches/prefixes/rescales/cold/entropy valueとcorrectionのto_bitsをbefore/after直接比較する。新84 named/96 assertions/6 CAP success、旧70 named/80 assertions/5 CAP success。depth0もCAP成功し、alpha更新loop空を保つ。

新depth8に旧固定payload/digest/CDF数値を適用しない。新固定datasetはgrammar/counts/classes/plain CRCの不変項目のみ旧Proof.validate_fixed由来の値で検査する（runs889227、primary1762795、alphabet257、rank/length889227、escape742、grammar0x58735a2b7383d755、branches[2725772,1099568]、classes[889227,620240,1216305,889227,64372,145969]、plainCRC433441561、有限CDF）。BのpayloadCRC/headerCRC/base_pool/CDFはB自身のencode/decode/repeatで比較する。

## 7. source graph、runner、条件付きABBA

想定graphは所有11file内で完結させる。`probe.rs`→`new_cts=integer_cts.rs`、`integer_pool=integer_pool.rs`（内部でnew_ctsを明示alias）、独立`oracle.rs`、`comparison.rs`、新`codec.rs`→新`model.rs`/新`e2e.rs`。同rootに旧`baseline_cts=../quaternary-cts-depth/integer_cts.rs`、旧`reference_cts=../quaternary-cts-q32/integer_cts.rs`、旧`old_pool=../quaternary-cts-integer-pool/integer_pool.rs`、凍結`fixed_math=../quaternary-cts-integer-pool/fixed_math.rs`を置く。rootは`use reference_cts as integer_cts`を旧pool専用に固定し、新CTSをroot integer_ctsにしない。旧`baseline_codec.rs`はAlpha codecの凍結数値/timer本文をテンプレとし、`old_pool as integer_pool`、`baseline_cts as integer_cts`を結線する。旧modelは旧baseline_codecのscopeから凍結参照。selfcheckは所有する新e2e.rsを旧/新scopeへ各1回includeし、旧depth5件・旧magic/newdepth6件・新magicを明示設定して全14Proof比較を行う（凍結旧e2eを編集しない）。新codec child moduleを持たせる場合もProof14fieldのみ共有し、数値routineは共有しない。

共通の凍結参照は`../causal-bayes-sais/bwt.rs`、`../rejected-binary-mix/packed_alphabet.rs`、`../direct-token/multi_range.rs`。Graphの旧/新alias誤接続、oracle→candidate関数呼出、QCANCEL/Math-U64/Alpha混入をrunner静的検査と独立readonlyレビューで拒否する。新magicはKHQCMQ21、旧AはKHQCID01。

計画の根拠として旧関連sourceを11file以内に限定して読んだ: depth integer_cts/model、q32 integer_cts、integer-pool integer_pool/fixed_math、mid-depth e2e/codec、alpha comparison/probe/codec/verify-alpha.ps1。追加の旧direct source探索は1fileまでが目安。凍結BWT/packed/range内部の追加調査が必要なら親へ返す。

後段`verify-q21.ps1`の非Executeはparser、静的graph、contract SHA、Alpha149 identities、basis、source identities、予算見積りを検査し、fresh出力は作らない。旧149+契約/Alpha RESULT/feasibility3+新11=163件のSHA/bytes/UTCticksをbefore/after/liveで比較する。既存identityの正確なschemaは`path/sha256/bytes/mtime_utc`（ISO string）。`ConvertFrom-Json -DateKind String`で保持し、mtime_utcをRoundtrip DateTime→UTC ticksへ変換してlive LastWriteTimeUtc.Ticksと比較する。既存recordsは`file/argv/exit/status`であり、arguments/exit_codeへ読み替えない。存在しない11file・plan count不足・余分case/schema field・CLI不足/追加を拒否する。失敗caseの名前とloop順もschema固定し、単にtotal一致だけで通さない。

親の確認・followup後に実装、非実行検証、編集停止/所有返却。その後親が独立readonlyレビューと数値/timer diff確認を回収してExecute1回のみ。code compile1回、codec CLIは`compare`、`selfcheck-old`、`selfcheck-new`、`abba INPUT`の各1回（計4）。前3CLI全合格時のみABBAへ進む。compile/version/rustfmtは別record、codec CLIに算入しない。失敗時の再compile/再CLI/好都合な時間を得る反復は禁止。

ABBA fixed inputは`build/khc-current-source-native-solid-20260923-group/all.group`、2811006B、SHA256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。1read、同binary、depth5のA/B/B/A、warmup0/1周。Aは旧pool/旧Math/旧update、478750B、payload478465/CRC3616798779、headerCRC621578488、base_pool0x0caac94407124a37、旧全statsの文字列とProofを再確認する。A/B相互frame/Proof数値同値は要求しない。

各runはencode1/decode1、全plain2811006byte・全Proof14fieldを比較する。二度目の同実装は初回の全frame/Proof/statsと直接比較（成功時repeat2件、A478750+B実size byte）。B1が483599B超過ならB1のdecode/plain/Proof確認まで完了し、status=size-rejected、run2/encode2/decode2/plain2/Proof2、repeat0、後続B/Aを実行しない。successはrun4/encode4/decode4/plain4/Proof4、repeat2、入力read1。B平均encode<A平均encodeかつB平均decode<A平均decodeかつsize<=483599のみ候補採用条件。時間差は1周診断で統計的証明ではない。

frameはRAMだけ、cloneしない。A/Bの初回referenceを各1枚move保持し、二度目比較後drop。最大current+reference3枚/1445948B、最後reference0。size-rejected時はdecode後即B/A frame解放。これはprocess RAM peakの検証ではない。encode/decode timer本文は凍結し、比較/Proof/JSON/log/dropをtimer外に置く。

正式size483599B、codec median574.5624ms、CPU15%、独立holdout/categories、4native、製品/API統合のgateは変更しない。本検証合格だけで7-Zip総合超えやgoal完了としない。

## 8. 失敗証拠と容量境界

失敗証拠は最初の失敗1件のみ、最大4096byteのUTF-8 JSON領域をreportに確保する。fixture名、loop index、seed、全ての最小scalar/vector入力、expected/actual Result、最初の異なるfield/indexを保存する。巨大stateは生成recipe（depth/class/path/seed/tamper）と最初の差だけを残し、全state比較そのものはRAMで実行する。frameは原入力の生成recipeと改変offset/value、最初の64byte以内の必要部分のみ。全input/plain/frameのdiskコピーやraw traceは作らない。truncateした場合はtruncated=trueとoriginal evidence byte countを示し、4KiBを越えて追記しない。4KiBは最大証拠枠であり、無意味なpaddingを保存しない。

後段出力は`build/khc-quaternary-cts-mixed-q21-20261003/`のEXE/report2件のみ（EXE<=1MiB、report<=512KiB、合計<=8MiB、見積り<=1.5MiB）。report count内訳/argv/exit/schema/source identities/失敗証拠を含めても予算を事前計算する。事前・事後disk-budget/free>=5GiB+8MiB、各write前size guard、timeout時は所有processだけ停止・回収する。PowerShell7.6.5/rustc1.98.1の契約SHAを照合、edition2024/frame_audit/primitive_audit/opt-level2/overflow-checks=yes/panic=abort/debuginfo0/link /DEBUG:NONE。Cargo/PDB/asm/表/共有cache/input copiesを作らない。

この最初のturnの完了条件は本planの保存、文書差分/bytes/SHA確認、未解決点・件数・graph返却、編集停止。実装・検証の成功は未確認。数値policy自体の未解決点はない。E2E移植時に新数値で指定malformed Errが異なる場合や凍結aliasが所有11fileで表現できない場合は、期待値を緩めず最小証拠を親へ返し影響する編集を停止する。alloc/IO/heap/write/sync fault injection、general8MiB入力、crossOS/native4、正式性能/CPU/holdout/製品統合は本planの実行範囲外で未検証。
