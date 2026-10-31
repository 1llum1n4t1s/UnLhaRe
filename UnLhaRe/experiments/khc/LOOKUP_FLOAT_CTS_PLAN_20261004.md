# Lookup-assisted floating CTS/pool：実装前の失敗計画

## 問い・範囲・所有

新private形式 `KHQCFP01`。旧quaternary depth5のBWT、next-use rank/run文法、packed alphabet、range coderを維持し、整数CTS/pool内部を順序固定f64へ変更する。旧frame同値は要求しない。モデル仕様は一構成・depth5だけ。全実装は指定worker-high一人が `lookup-float-cts/` のみ所有、親はこの計画と実行・採否を所有する。製品、旧source、公開API、LZH方式、version、依存、x86、Git、公開、削除は対象外。

これは旧Q32同値最適化ではなく、現代CPUのscalar浮動小数点と既存lookup gridを使う別数値policyのscreen。以前のf64機会診断は理想確率と別oracleを全枝比較し、wire/速度を検証していない。本候補はcanonical grid値をstreamごとに生成し、hot pathのln/exp transcendentalとchecked u128/i128によるpool/CTS計算を取り除く。成功見込みや速度短縮量は未証明。

## 固定数値仕様

- Counts四表、row hash、初期値1・増分2・32768到達時ceil半減、pool初期係数[.25,.25,.25,.25,0]、勾配学習率1/256、係数clamp[0,2]、uniform1/4096、tree/六class/historyは旧depthモデルの構造を維持。
- Mathのcanonical Q48 l/e gridとln_count表を旧 `fixed_math::Math` で生成しf64へ変換する。`ln_cts` は正の有限値の2進指数と仮数に分け、ln gridの隣接二点を順序固定の線形補間。`exp_neg` はln2で指数部を分けe gridを線形補間する。dのdomainは有限0..128、exponent>=32は0へcutoff（旧Q32の指数部cutoffを継承）。f64のln/exp/powはhot pathに使わず、mul_add/fast-mathも使わない。計算順はsourceに固定する。
- CTSはclass当たり4進context木depth5。KT=(raw+.5)/(合法prefixのraw和+.5*k)、各levelでweight*own+(1-weight)*child。観測前Snapshotのweight/own/mixedを用いてposterior=weight*own[child]/mixed[child]、alpha=1/(class_after+1)、次weight=alpha+(1-2*alpha)*posterior。leaf weight=.5。全非合法tailは0、全値は有限・合法範囲、raw/class cap3825340。各levelのKTはdenominatorの逆数を1回求め各childへ乗算する順を固定し、直接除算の独立oracleと比較する。
- poolは各childの5特徴内積、maxを引いた指数表、sumで正規化したq、uniform混合pを順序固定で計算。CDFはpをsumで正規化して32768へfloor配分し、残りはfraction降順・同値child昇順のHamiltonで配分する。合法freq>=2（prefix1は32768）、tail0、total32768を検査する。
- observed childはpredict引数に存在しない。学習factor=4095*k*q_child/(4095*k*q_child+1)、gradient=factor*(feature_child-sum(q*feature))。準備・validation後だけcommit。Snapshotは外から変更不能にし、serialと参照するraw/weight/historyを検査する。正確な旧integer軌跡への同値を主張しない。

合法raw cap下ではKTの各合法childは少なくとも0.5/(CAP+2)、CTSはその凸混合。四count特徴のlnは0..ln32768、CTS特徴はln(0.5/(CAP+2))..0、各係数0..2なのでscore差の保守的実数上界は8*ln32768−2*ln(0.5/(CAP+2))（約115）となる。domain128には余裕がある。これは実数上界で、f64の全軌跡/CDF端点の網羅証明ではない。

診断entropyは旧と同じ `-log2(freq/32768)` を維持し、補間lnへ置き換えない。この費用も内部encode/decodeの診断時間に含める。新pool/CTSの予測用ln/expをlookup化することと診断量の近似は分離する。

## コード前に列挙する失敗と検証

1. 数値domain：0、NaN、Inf、負probability、weight範囲外、prefix0/5、child>=prefix、raw cap、serial overflow。拒否後のモデル全state直接比較で非mutationを確認。float to_bitsでの比較を使いdigestだけへ依存しない。
2. lookup：canonical table生成失敗、端点index越え、ln domain、exp cutoff、補間非finite。固定非対称syntheticでln/exp対std式、KT/CTS対独立順序の式、pool確率の有限性/CDF/gradientを検証する。誤差は絶対値|candidate-reference|、上限はln/exp各2e-7、pool probability1e-6。cutoff前後、2冪、grid端点、合法最小CTS確率も含める。これは連続旧モデルの同値を保証しない。
3. codec：空、1byte、反復、周期、全byte、小randomのinput→frame→plain→repeat-frameを全byte比較。encoder/decoderの全Proofを直接比較しCDF entropyはbitsで比較。new/old magic混同、truncation、header/payload corruption、depth改変、invalid fields、非正準alphabet/escape等の旧E2Eを使える範囲で継承し、不能は列挙する。新unit testを追加しない。
4. 固定group：入力2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。各方式の完全復元、反復全frame、文法Proofの固定値を検証する。新frame<=483599Bを最初に判定。不通過なら性能sweepやdepth/係数調整をしない。
5. 資源・実行：源泉graph全閉包のidentity(path/SHA/bytes/mtime_utc)前後照合。compile60秒、各CLI120秒、stdout64KiB/stderr16KiB、既存root拒否、入力8MiB/coder旧cap、source300KiB、EXE1MiB/report256KiB、fresh build8MiB。frame/plain/inputはRAMだけ、source外の成果物はEXEとreportだけ。単体rustc/edition2024/opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE。Cargo/PDB/rawtraceなし。
6. 最小screenの合格後だけold/new/new/oldの1周warmup0を内部encode/decode境界で診断する。旧frame478750B/newは新policy、各方式のrepeat決定性が必要。単発診断を正式速度、quiet CPU、7-Zip同session勝利へ読み替えない。両方向短縮しなければ未採用とし有利な再試行をしない。

## 基礎と残る総合条件

親の事前 `git diff --check` は成功。旧Q32 depth5の正当性は既存証拠で今回の再実行ではない。新形式はこの計画だけでは未実装/未検証。opop観点は親がPerformance/Hardening/Testerを主担当、Modernizer/Normalizer/Cleanerは公開移行・依存変更・削除なしとして非該当。Asyncは単体同期、Startupは表構築時間をencode/decodeに含めて確認。外部仕様照会は新numeric policyの採否には不要。

4環境・opt間float軌跡、完全書庫/製品契約、holdout/category、同memory/thread、正式quiet full CLI encode<574.5624ms、同境界decodeで7-Zip超えはすべて未達のまま。浮動仕様を一般にportableと呼ばず、後続native相互検証を必須とする。総合goalを局所PASSへ縮小しない。
