# log-linear pool実装前の失敗・独立検証計画

本候補は診断f64のみ。旧quaternary-context、旧proof/source/contractは変更せず、topology/count/context/grammarを継承する。変更はpoolの予測と同時weight更新だけ。

数値許容差は実行前に固定する。各probability/gradient/weight比較は `abs(actual-reference) <= 2e-10*(1+abs(actual)+abs(reference))`、finite differenceはh=1e-5・絶対差2e-6、集計bitsは絶対差1e-4。count/token/key/枝/grammarは整数の完全一致。失敗後にtolを広げない。

- countの対数とnormalized probabilityの対数の相殺、softmax安定化、uniform混合、gradientの符号/係数を誤り得る。実装はln(count)・max差exp、独立oracleはln(count/prefixTotal)・通常exp/sum。非対称counts/weights・prefix1..4の全childを照合する。
- gradientを順次weightで計算する、counts更新後のfeatureを使う、learning rate/uniform/clampを変える失敗があり得る。4gradientを同一の更新前snapshotから算出し一括commit、別count/weight配列のoracleへ全実測枝のprobability/gradient/更新後weight/countと終端stateを照合する。固定rate1/256・uniform1/4096・clamp[0,2]、gridや自動変更なし。
- synthetic finite differenceでln(observed probability)の各weight微分を独立確認する。h=1e-5中央差分、prefix1..4の全child×4weights。clamp下端/上端、uniform countsのzero gradient、forcedchild1のp=1/zero gradient/weight不変、zero weightの一様qを検証する。
- 旧topology・truncate・known rank・causal更新・hashの移植間違いを検出する。256/257alphabetで全66049token/limit逆変換・独立区間oracle、internal142ずつ/maxdepth7、invalidprefix0/5、rankContext0/8/invalid9を継承。順位はactive vectorと独立positions/cursorから889227全run照合、run完了前historyと別historyの一致、canonical両digest一致を維持する。
- count初期1/加算2/rescale32768/ceil-half、合法prefix条件付け、query/update順、hash collision扱いを誤り得る。別整数配列との全枝比較・強制rescale・終端全state照合を行い、checksumだけで正当性を主張しない。
- loss単独expertとoldflatが旧と違うとpool比較無効。rank/length各889227、escape742/5936bits、primary1762795、alphabet257、grammarと枝件数、4expert component bits、oldflat component bitsを前reportへ照合する。Kahanのcomponent和/全体を照合し、前算術mixtureとの差を報告する。
- zero/NaN/inf、範囲外weight、数値誤差、pin変更/未知import/不在input/proof、同root再利用、child120秒/streams65536超過、EXE予約1MiB/report512KiB/8MiB超過を拒否する。source/compiler/runtime/input/proof/importのreadlockと前後SHA。parser/pin/import/preflightを先行し、親確認後compile/runは一度だけ。未知失敗は有界JSONと親報告で止め、同条件再試行なし。

fresh出力先 `build/khc-quaternary-logpool-opportunity-20261002` のEXEとJSONだけを保持する。予想300KiB以下。Cargo/PDB/cache/rawtrace/features/table/frame/restoreは作らない。guardは事前事後確認で強制write quotaではない。

機会gateはmixed entropy + escape5936bits <3866504bits。未達なら整数wire/full/正式benchmarkを起動しない。達成でも整数化primitive/実frame/速度/holdout/native/製品統合は未検証であり、全goalは未達。
