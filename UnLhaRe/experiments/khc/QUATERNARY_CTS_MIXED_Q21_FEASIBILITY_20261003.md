# 別研究形式: CTS/pool Q21とlog/exp Q32の混合精度候補

## 現在の判断

意味保存のQCANCEL、Math-U64、Alphaは正しさ合格でも両方向平均短縮せず未採用。depth5の旧実装が基点のまま。次は私的な新形式候補として、CTS/pool確率と学習重みをQ21、log/expを旧Q32・Q48 Mathのまま分ける案に数学的成立余地がある。単なるQ定数差替えでも旧Q32との数値同値でもない。実装・圧縮率・実速度・holdoutは未検証。10倍改善や7-Zip総合超えを保証しない。

readonly analyst cts_precision_feasibility（gpt-6.1-sol/medium）が10source以内でCTS/Math/pool/model/range/headerを調べた。親も現Math/pool全文、model/codec/range呼出元、q32 KT/Hamiltonを読み、下記の反例と整数範囲へ接続した。外部資料やサービスを使用していない。

## 単純な低精度化が破綻する点

1. after=Q21=2097152からfloor(Q21/(after+1))が0になる。CAP3825340内なので旧zero alpha拒否へ入り、CAPまで更新できない。depth0はloop空でこの拒否へ入らない。Q20ではさらに早い1048576から破綻する。
2. 合法raw=[Q21-1,0,0,0]、prefix2ではKT mass=[2Q21-1,1]、total=2Q21。Hamiltonの商は[Q21-1,0]、両余りQ21、残数1がchild0へ渡り[Q21,0]となるためvectorが拒否する。alphaを最低1にするだけではこのpredict破綻を直せない。
3. mixtureは現在>>32/mask Q32-1、Mathはscale32とQ48→Q32 shift16、pool学習deltaは/256が固定。Qの一部だけを変えると総量・対数単位・学習幅が整合しない。
4. Node/Kernel/RawSnapshotの型と固定9段はQだけでは縮まらない。Q48表構築・exp補間のu128も残る。「低精度化で全hot divisionとRAMが軽くなる」という主張は成立しない。

## 次prototypeへ進む場合のpolicy案

まだ実行契約ではない。実装前にこれらを一意な新仕様と失敗計画へ固定し、旧source/契約/結果は上書きしない。

| 項目 | 推奨する新policy | 理由 |
| --- | --- | --- |
| 確率・重み | Q_PROB=2^21、非leaf/leaf意味を維持、pool重み[0,2Q_PROB] | unsigned posterior分子が2^63まででu64に収まる |
| KT | active各childに1を予約し、残量Q_PROB-prefixを2raw+1へHamilton配分 | CAP内のzero確率を防ぐ。floor後max1再正規化とは別のpolicy |
| CTS係数 | alpha=max(1,floor(Q_PROB/(after+1)))、retained=Q_PROB-2alpha | CAP内のzero alphaを防ぐ。新スケジュールであり旧同値とは言わない |
| log/exp | 凍結Q48→Q32 Mathをそのまま参照、CTS nをchecked_mul(2048)で旧ln_ctsへ渡す | 既存LUTとMath fixtureを保持し、Math単位を混在させない |
| score | Σ(weight_Q21×feature_Q32)/Q_PROBをゼロ方向へ丸める | Q32 scoreなので旧exp_negの入力単位と合う |
| q/p | exp mass_Q32をQ21へHamilton配分。q active0を許可し、pに従来uniform smoothingを加える | rare q0/factor0を合法のまま、pと最終CDFを正値へする |
| 学習 | expected/gradientをQ32 log単位で順に整数化、delta=gradient/524288、その後weight+deltaをclamp | /256とQ32→Q21の2048倍率を明示。丸め順を変更しない |
| 改変pool Prediction | active featureは下記の行別domain、inactive featureは0を新拒否契約にする案 | 正常値の上限だけで全入力のi128をi64へ置換してはならない |
| range | CDF総和32768・inactive0・全active frequency>=2を保持 | 現range NORMALIZE=2^24/MAX_TOTAL81920へ影響なし |
| format | 別magicでQ21/KT予約/alpha最低1/Math32/学習順policyを識別し、未知/旧magicを早期拒否 | 旧KHQCID01はdepthだけで新数値policyを識別できない |

Rust checked_shl(11)は上位bit喪失の検査ではない。CTS vectorを先に検査し、checked_mul(2048)を使う。負数の/2^bを算術右shiftへ置き換えるとゼロ方向丸めが変わるので採用しない。

## 正常域の整数範囲

| 演算 | 正常域上限 |
| --- | --- |
| CTS mixture mass/total | Q_PROB²=2^42 |
| CTS posterior numerator | Q_PROB³=2^63 |
| KT mass×Q_PROB | (2CAP+1)Q_PROB<2^44 |
| count feature_Q32 | 0..44655667077 |
| CTS feature_Q32 | -62517933908..0 |
| 全feature絶対値 | <15Q32=64424509440 |
| score積和絶対値 | <150Q_PROB Q32=1351079888211148800<2^61 |
| score下限/上限 | -125035867816..357245336616 |
| 最大score差 | <=482281204432<128Q32=549755813888 |
| expected/gradientの積和 | <15Q_PROB Q32<2^57 |
| delta絶対値 | <122880 |
| q Hamilton mass×Q_PROB / total | <=2^53 / <=2^34 |
| p/factor分子 | <=16381Q_PROB²<2^56 |
| p×CDF total | <=2^36 |

featureの範囲は旧LN2=195103586505154、LUT単調性・指数・整数補間の境界から得られる。count featureは非負、CTS featureは非正、weightsは非負なのでscore差も旧exp域内。最高scoreのexp massはQ32であり全massゼロにならない。p minimumはprefix4でも128、CDF換算で最低2を保持可能。Q48構築・補間のu128は残るため、時間寄与は別途測定する。

正常域以外の反例: prefix1/q,p=[Q_PROB,0,0,0]でfeature=i64::MAXの改変Predictionをobserveへ渡すと、Q_PROB×featureはsigned64を超える。現i128 bodyはこの積を扱える。新domain拒否を宣言するか異常入力経路へi128を残すかを実装前に決める。上表を根拠に黙って入力契約を狭めない。製品APIにはこの新private policyを混入させない。

## 必要な検証・容量・採否

最小prototypeは新CTS primitive/sealed state、pool、model結線、codec magic/Proof、rootとE2E。Math/BWT/packed alphabet/rangeは凍結参照できる。旧型を残す場合もQ32 primitive関数を新Q21のoracleとして呼んではならない。独立u128基準は同じ新policyをexact演算で記述し、candidate u64/i64の全成功値とErrを直接比較する。共通policy自体の誤りはanalytic goldenと全codec E2Eで別に検出する。

- KT: prefix1..4、全heavy位置/tie、raw Q21-2/Q21-1/Q21/CAP、未使用rawを含むCAP和、全frequency正値と総和。alpha: after1/Q21-1/Q21/Q21+1/CAP/0/CAP+1。
- Math接続: count1/32768、CTS1/Q21、不正n、score差上下端/exp cutoff。q0/rare factor0、weight0/2Q21、signed丸め、改変feature/overflow拒否。
- 全depth0..8、pure predict、改変/stale/foreign/rebased、current guard優先、CAP exact成功、prepare全完了後commit、拒否後全state不変。
- 新magic/header短縮/CRC/depth/正準alphabet/範囲coder terminationのforge E2E、全plain byte、canonical再encode、encode/decode全Proof/CDFbits一致。旧Q32とのframe/digest/CDF一致は要求せず、grammar/class counts/plain CRCなど不変条件と新出力固有値を区別。
- fixed development inputのsize<=483599Bを維持し、その後独立holdoutとカテゴリで再評価。成功候補だけ同条件の正式時間/CPUへ進める。過去の別binary/別時期の時間比から改善を断定せず、好都合な反復や評価条件緩和をしない。

出力見積りとsource/compiler/runtime識別を実行前に固定する。新Cargo target/巨大table/生trace/入力・復元コピーは不要。既存のsmall rustc scopeと8MiB budget/空き5GiB guardを使う。固定証拠を削除して空きを作らない。現goalはactive、正式速度/CPU/holdout/4native/製品統合は未達のまま。
