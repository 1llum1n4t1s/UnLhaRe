# 単一の適応suffix KT expertでCTS計算を置き換えるsize-first候補

新しいアルゴリズム研究として、既存BWT/packed grammar/primary/Bayes/rangeを保持し、7 classそれぞれのCTS expertだけを置き換える。元CTSは1bit当たりKT17回・mixture16回・posterior16回・switch alpha1回のsource経路を持つ。互換な省略ではなく別形式`KHBADP01`とし、製品のdefault/API/versionには変更を入れない。

候補は7 class、直近16bit history、各二分prefix nodeのzero/one累計を維持する。予測は現在bitを読まず、depth16から1へ過去countを調べ、total>=32の最も深いnodeを1個選ぶ。存在しなければrootを選ぶ。この32は一構成の固定選択規則であり、失敗後に閾値/depth/class/grammar/混合係数をsweepしない。選んだnodeのQ32 Jeffreys KTを凍結exact KT helperで1回計算し、元Q32→Q15丸めで返す。全17nodesのcountは観測後にleaf→root順で増やし、同class historyだけを進める。primaryとclass Bayesは元のまま因果的に予測・学習する。各bitにおけるCTSexpertの17KT/16posterior/16mixture/alphaを1KTへ減らすが、実時間や圧縮率の改善は仮説である。

node indexはheap index、latest-bit-firstという元の順を保つ。上限562036803/class、fallible allocation、class/node bounds、count overflowを維持する。Predictionには予測時のhistoryとclass観測数を保持し、別snapshot/別class/stale更新を拒否する。Nodeはrepr(C)のu32 count2個とし、8Bのcompile-time assertionを設ける。node storageは8×131071×7=7339976B、kt table storage524296Bとの合計7864272B（Vec等のmetadata/allocator overhead/他modelを除く）でありpeak memoryではない。kt tableは共有Model所有1個を用い、選択/更新は多threadや外部学習を使わない。Model観測capは固定8MiB入力のgrammar経路から到達する本仕様の上限として保持する。

実装前の失敗条件: source/correspondence/pin/固定入力不一致、predictに現bit/未来symbolの参照、node順やcount更新の非対称、cap/overflow/class誤受理、選択予測のQ32/Q15範囲違反、非決定的frame、復号/CRC不一致、旧magicとの混同、破損後の公開、no-clobber違反、120秒timeout、input/source変化、owned tmp/reparse残存。元研究CLIの既存安全性の限界は保持・明記し、製品のparent-handle安全性と同一視しない。

新root `build/khc-adaptive-suffix-kt-20261001`、既存拒否、自動retryなし。std-only rustc1.98.1/edition2024/panicabort/opt3のnativeとforcedportableを作り、空/1byte/全byte/反復/周期/seeded random/固定groupの全byte往復と両variantのframe一致、固定反復、代表異常系をCLIで検証する。codec wrapperは元KT reciprocal codecからコメントとmagicだけを変更した全文対応を検査する。新unitは書かない。

固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、size<=483599Bを先に評価。旧KT reciprocalの483469Bは比較用sizeであって新形式の予測値ではない。size不合格はこの一案を閉じ、速度/holdout/parameter sweepへ進まない。通過時だけ別契約のsingle-thread fullCLI encode strict<574.5624ms、native11files solid、warm1+9/同session/quiet15%/peak memoryを評価する。

この有限size E2Eは独立BigInteger oracle、全Model state数値、全悪入力や4OS/ISAの証明ではない。新しい独立作者監査は未実施。総合7-Zip超えはholdout/カテゴリ/同境界decode/資源/4native/製品の未達を含む全体goalのままである。
