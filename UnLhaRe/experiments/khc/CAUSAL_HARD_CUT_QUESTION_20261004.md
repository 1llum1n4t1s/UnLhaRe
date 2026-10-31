# 次の一構成：因果的cached hard-cut tree

static MDL class2/5は費用494389BでNO-GO。有益nodeの事後選択2件/4724branchesも速度主案にならない。未測定schedulerは新quiet条件の正式入口で17%となり候補CLI0、同条件の自動再試行をしない。独立した演算削減候補をsize-firstで反証する。

CTSの全6階層KT CDF＋5混合＋5posteriorを、過去だけから選んだcached context tree cutへ置換する。予測では選ばれた1nodeのKT CDFだけ、観測では6nodeの観測childの整数価格とraw更新、5nodeの4子best費用和だけ計算する。costを更新してから当該childを予測する先読みは禁止。全部のprefixイベントを共有するclass/history cut、prefix1でもraw/historyを更新。

6class×1365node、各nodeはraw:[u32;4]/own:u64/best:u64/split:bool。scoreはQ8整数、凍結prices.rsの既存一次近似PRICESだけを再利用。positive xのexp=floor(log2 x)、index=raw xを14bit整数部へ右/左shiftして16384..32767に正規化、log_Q8(x)=(exp+1)*256-bit_price(index,false)。観測KT price=log_Q8(2*sum(raw[..k])+k)-log_Q8(2*raw[child]+1)。prefix1は0。型範囲上限CAPとu64 overflowをpreflight。これは近似価格の選択規則で、実CDF entropyと同値ではない。

初期own=best=0/split=false。depth5はleaf。非leaf best=min(own,256+sum(4child.best))、同点leaf。更新されたpath子の次bestと他3兄弟の現bestからbottom-up計算、全6next状態を準備してからcommit。best(root)は過去を見た最良cut scoreで、実際に毎時刻選んだ予測の累積lossやregret保証ではない。cold/分布変化の切替遅れを反証する有限fixtureと、実mixed CDF lossを別集計する。

原lookup-float-cts/model.rs/float_pool.rs/float_math.rsとgrammar/frontendを直接参照し、原pool学習/hashcountsは変えない。Cts private interfaceだけ差し替える新private root。原Modelのframe_audit helperはコンパイルせず、今回primary_audit有限fixtureで新Ctsを検証する。新primaryは原float_ctsのkt/vector/pathを凍結再利用し、posterior/mixtureを実行しない。f64 pool全4native決定性は未証明、integer cutだけでportable wireを主張しない。

モデルheaderは保存しない診断。全coded actual pool CDF lossをceil/8＋side3079（2048 reserve込み）で483599Bへ比較し、未達ならcoder/frameへ進めない。score-Q8/rate/depth/penalty sweepなし。速度の成功は別の固定warm1+9/full CLI・same resource/quiet gateが必要。decode、holdout/category、完成書庫/API、4nativeを満たすまで総合GOAL active。
