# categorical分岐系列CTSの機会診断: 実装前契約

## 根拠と反証

symbol×recent report91F6F447ED4B29279765F334680847847B1BD27EAD22073CD9E17616D9CAE5C2は前logpool比1928.726416byte相当改善だけで、固定機会予算から32975.800818byte相当不足。追加tableを広げるだけでは十分という証拠はない。

actual balanced codec9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B、cts_model9CFC6DF121A3711D704ED9F36F8D068F03A788DBC9F1A67118BB0CA89BD2F647、bayes_modelE50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422は、7grammar class別の過去16bit suffix KT/CTS予測を用いる。quadにはclass内の連続分岐系列予測がない。情報条件だけでなくprimaryの推定・較正/topologyも異なるため、CTSを加えれば成功するとは仮定しない。新CTS候補は固定entropy機会gateで反証し、未達なら整数wire/full/正式benchmarkを起動しない。元のsize/速度/CPU/holdout/native/製品条件を緩和しない。

## 固定変更範囲

新dir quaternary-cts/、fresh root build/khc-quaternary-cts-opportunity-20261002。基点は凍結4expert quaternary-logpool/opportunity.rs SHA09A858DA1FD1C712D548D53AA580747CF68B74266419A4E1419369961E3B5C6D/report D84D70C2D64A366C073DEC83E5019DF24C6B34F4538B48435284DEC914C7A320。symbol×recent tableは本候補へ持ち込まず、4expert+CTSの5特徴で比較する。小改善の追加tableを重ねず、系列予測の効果と費用を切り分けるためである。両旧候補のproof/sourceを保持する。

topology/alphabet/nodeID/limit/known rankContext、causal run履歴、canonical grammar、escape、既存4count/hash/rescaleを維持する。CTSは新診断f64仕様であり、旧Q32 binary CTSのwire・数値・速度と同一とは主張しない。

### 因果class・履歴・木

6classに分離する。component rank/lengthそれぞれ、full topologyのrootはclass0/3、区間[4,A)または[32,A)のband nodeは1/4、他の内部nodeは2/5。classは観測childやfuture tokenを使わず、現在到達したnodeのfull区間から決まる。合法prefixで区間を切ってclassを変えない。

各classに16bit履歴（直近8個のquaternary child）を0初期化する。毎枝の観測後だけ `history=((history<<2)|child)&0xffff` を更新し、run完了を待たない。同classに現integerの既知prefixと前integerの系列が入る。predictionはclass/prefixだけを受け、観測childを引数に持たない。forcedprefix1もchild0として観測・履歴/count更新する。

固定depth8、levels9、full4分岐heap nodes=(4^9-1)/3=87381/class、計524286node。depth0=root。過去履歴の最新childから順に `index_next=4*index+1+((history>>(2*(level-1)))&3)` で9nodeを照会する。起動時の不足履歴は0padding。動的table/cache/gridを作らない。

### KT・CTS予測と更新

各CTS nodeは raw observation counts[0;4] (u32)とweight0.5 (f64)。raw totalとclass observationsの固定診断capは3825340。half-count確率は合法child j<Kに対し `(raw_j+0.5)/(sum_legal_raw+0.5*K)`。K1..4で、raw countsをrescaleしない。既存4expertのrescaleは従来どおり。

予測は更新前snapshotだけから9levelの合法KT vectorを得る。leaf(depth8)のmixed vectorはKT、その上で `mixed_l,j = w_l*KT_l,j+(1-w_l)*mixed_(l+1),j` とbottom-upに混合する。各vectorは合法prefixに対し正で正規化される。root vectorがCTS expert probability。

観測後、class after=n+1、alpha=1/(after+1)、retained=1-2*alpha。depth0..7のsnapshot posteriorは `w_l*KT_l,observed/mixed_l,observed`、next weightは `alpha+retained*posterior`。丸めで数学範囲を微小に外れる場合のposterior/next weightは[0,1]へclampするが、事前tol外の逸脱/NaN/zeroは拒否する。leaf weightは0.5を保つ。全weightは保存済みKT/mixed/weights snapshotから計算し、counts更新を参照しない。path上9nodeの観測raw countを各+1、その後class observations/historyをcommitする。cap/invalid検査はmutate前に行う。

### 5特徴log-linear pool

各branchのfeatureは既存4expertのln(count_j)、5番目ln(CTS root probability_j)。oracleは既存4expertをln(count_j/legalTotal)、5番目は別CTS oracle probabilityのlnとして別softmax/gradientを使う。合法prefix分母のchild非依存constantはsoftmaxで相殺する。

既存4weights初期.25、新CTS weight0.0、global row4608、rate1/256/uniform1/4096/clamp[0,2]を固定する。5gradientを同じ更新前snapshotから同時計算・commitする。その後CTSを上記snapshotで更新し、既存4tableも従来規則で更新する。poolのloss/重みをCTS node posteriorへ混入させない。旧mix weights/stateの一致は要求せず、既存4table/lossを継承比較する。parameter grid/結果後自動変更/同条件retryなし。

## 実装前失敗計画・独立検証

新dirのopportunity.rs、cts_model.rs、verify-opportunity.ps1、FAILURE_PLAN.mdを担当一人が所有し、コード前にFAILURE_PLANを保存する。数値tol2e-10*(1+absA+absB)、FD step1e-5/abs2e-6、集計bits abs1e-4を固定する。失敗後のtol拡大は禁止。

別class/history/path/count/weight配列を持つCTS oracleは、u64 half-count初期[1;4]/観測+2、履歴を除算と剰余で分解したpath、別形式のposterior mass/(mass+childmass)とswitch重み式を用いる。全実測枝でclass/path/9KT/mixed vector/全更新weight/count/history/observationsを比較し、終端の全node/class stateも比較する。主実装snapshotをoracleへコピーしない。classは独立topology区間oracleからも検算する。

実装前に、非対称KT/prefix1..4、起動0padding、class分離、履歴の16bit wrap、最大heap index、深さ別prediction/update、初回alpha=.5、stationary/repeated/alternating系列、forced1、cap/invalid非mutating拒否、weight丸め端、符号/勾配/同snapshotを列挙し、それぞれ有界memory caseで照合する。小depth0..2の全history/child/prefixも独立再帰式と比較する。5特徴の内点50中央差分とCTS weight0の正学習/負clamp、uniform等を継承する。新仕様はdiagnosticのみで、整数wire proofと同一視しない。

元tree66049/順位889227/oldflat1778454/canonical digest/枝3825340を継承する。既存4expertのrank/length8損失、cold/rescale/grammar/prefix/depthとoldflatを前logpoolへ照合する。CTS component/class損失とCTS単独損失、depth別cold/query件数、class counts、最大数値差、mixed差を小JSONに記録する。raw trace/table/featuresは保存しない。

終端値数はbase4count+5poolweights3187200、CTS524286nodeの4count+1weight2621430と6classのhistory/observations12、合計5808642を予定する。実際のshapeから独立算出し、全値比較で裏付ける。cached total等は比較するが二重に値数を水増ししない。

gateは mixed entropy+共通escape5936bits <3866504bits。偽なら不採用。真でも整数primitive/range丸め/実frame/正式性能/holdout/native/製品/APIは別途未検証であり、7-Zip超え完了とはしない。

## 容量・実行・境界

one opt2/overflowyes EXE+小JSONだけ。fresh8MiB cap、予想400KiB以下（CTS実装を含むため前候補300KiBから見積りだけ変更、予算は維持）、EXE1MiB/report512KiB予約。child120sec/stdoutstderr65536、debuginfo0 /DEBUG:NONE。6classのCTS tableとoracleはメモリだけに保持し、Cargo/PDB/cache/frame/restore/rawtrace/table出力を作らない。guardは事前事後確認で強制write quotaではない。

rustc1.98.1/bundledpwsh7.6.5固定、source/import/compiler/runtime/input/proofをpin/readlock/前後hash照合。新cts_model importもpin/parserに含め、未知importを拒否する。既存balanced CTS/helperは参照資料であってcompile importへ含めない。親の最終source/hash確認後にcompile/runを一度だけ行う。旧source/proof/rootを改変せず、既存root再利用と同条件retryを拒否する。stage/commit/push/version/公開/外部書込/x86/共有cacheは禁止。全総合goalはactive・未達。
