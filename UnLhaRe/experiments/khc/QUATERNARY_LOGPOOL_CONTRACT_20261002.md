# 4分岐構造文脈のlog-linear pool機会診断: 実装前契約

## 根拠・反証

前算術mixture report D5F126BCD9F86D0A355AE7A8F5CB1550E23DA5F58A8F045E5C5281E055357D99はold flatから40653byte相当減ったが、固定payload予算から51490byte相当不足。mixedは単独global/symbol/recent/jointのどれよりも良かった。次は各expertの情報を加算scoreから結合するlog-linear poolを試す。事前に成功を仮定しない。固定payload見込みが未達なら整数wire/full/正式benchmarkを起動しない。既存候補の測定を再試行したり、条件やparameter gridを変更したりしない。

## 固定変更範囲

新dir quaternary-logpool/、新root build/khc-quaternary-logpool-opportunity-20261002。前sourceのtopology、half-count/rescale、global4608/hash各2^18、rank/length sideinfo、causal recent/previous、固定input/token列/validationはそのまま継承する。算術posterior/share weightsだけを次のlog-linear poolへ置換する。旧source/proof/contractを書き換えない。

global rowごとにa_i=0.25（4個）を初期化。合法child0..K-1に対し
s_j=sum_i a_i*ln(c_ij)。
各expertのprefix totalのlnはjに依存せずsoftmaxで相殺されるため省略する。lnはdiagnostic f64、future整数wireとは別。q_j=exp(s_j-maxScore)/sum_h exp(s_h-maxScore)。
観測childのprobability p_j=(1-1/4096)*q_j+1/(4096*K)。
小さいuniform mixtureは有限確率を保証するが、これで実range丸め・frame gateを保証したとは言わない。

観測後、counts更新前のfeaturesを使ってgradientを計算する:
a'_i=clamp(a_i+(1/256)*((1-1/4096)*q_observed/p_observed)*(ln(c_i,observed)-sum_j q_j ln(c_ij)),0,2)。
learning rate1/256、uniform1/4096、範囲[0,2]は本候補で固定、手動gridや結果後の自動変更なし。最大feature差はln32767程度で、更新は小さな範囲へclampする設計だが、汎化/速度優位とは未証明。全4gradientを同じprediction/counts/weights snapshotから同時算出してcommitし、順次変更weightで次gradientを計算しない。countsはその後に旧規則で4expert分更新する。

新oracleは通常normalized expert probability ln(c_ij/prefixTotal_i)を用いる別score式、通常exp・sumのsoftmax、別のcount/weight配列でlossとgradientを比較する。denominator相殺と正符号を数学だけでなく非対称count/weight/prefix1..4の計算で確認する。小synthetic stateではfinite differenceでgradient方向を独立確認し、clamp境界/均一counts/forcedchild1を検証する。全実測枝で別式oracleへ比較し、終端count/weightも一致させる。floating toleranceを実行前失敗計画に固定し、不一致後に広げない。

旧単独expert lossも集計し、同一counts/token列なので前reportの4expert・oldflat component bitsへ照合する。変わった場合はpool比較無効として拒否する。元grammar oracle/digests、tree66049/node142/maxdepth7、counts/rescales全枝の照合を継承する。

## 実行・容量・完了範囲

loss/branch counts/gradient検証件数/state digest/identityだけ保存し、rawfeatures/table/traces/frame/restoreは作らない。payload機会gateはmixed entropy+共通escape5936bits <3866504bits、同じ固定条件。前算術mixtureとの差も報告。gate falseなら不採用。gate trueでも整数化primitive/full/実frame/速度/holdout/native/製品まで未達であり、全goalを縮めない。

1opt2/overflowyes EXE+小JSON、fresh8MiB cap/予想300KiB以下/report512KiB、child120s/stdoutstderr65536、debuginfo0 /DEBUG:NONE、Cargo/PDB/cacheなし。source/import/compiler/runtime/proof/inputをreadlock/pin前後照合。単体rustc1.98.1、bundledpwsh7.6.5固定。コード前にFAILURE_PLANを保存し、parent最終source確認後にcompile/runを1回だけ行う。existing root上書き/同条件retry/未知失敗後のtol緩和なし。全旧証拠保持。Gitstage/commit/push/version/公開/外部書込/x86/共有cacheは除外。

