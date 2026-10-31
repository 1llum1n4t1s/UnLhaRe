# 因果的2モデルmixtureと正準alphabet表 — 実装前契約

既存CTSのD16/Q48、primary予測器、grammar、Q15 range coder、入力は凍結する。固定group 2,811,006 bytes / SHA-256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、11 entries、size gate ≤483,599 bytes、full single-thread encode <574.5624 msを変更しない。今回の実装は診断のみであり製品format/default/API/deps/version、UnLha32Re、holdoutを変更しない。過去のsource SHAは過去のbinary/reportに対応し、現在値へ読み替えない。

## 先に反証する失敗

- 現bit/未来rank/runを見た予測、事後の良いモデル選択、component更新へのmixture確率混入。
- underflowでcomponentを永久に捨てる、classを跨ぐposterior、非有限loss/確率、Q15量子化やflushを無料にする。
- alphabet permutation rankの幅をfloatで誤判定、bitmap padding/duplicate/sentinel/範囲/余分なbyteを受理、復元不能な格納。
- diagnosticの追加でnormal出力・component loss/countを変える、flush二回、失敗後の公開、既存work/outputを上書きする。
- real-valued Bayes regretを実Q15符号長や速度の保証と誤記する、metadata自己復元をaux/full-frame復号と混同する。

## 単一構成

7 decision classesそれぞれでprimary/CTSの初期priorは1/2。componentごとの累積Q15 negative log2 likelihoodをf64で保持する。各観測前、`wPrimary=1/(1+2^(Lprimary-Lcts))`を負の絶対差のexp2で安定評価する。underflow時も累積loss差を保持し、将来回復可能とする。raw mixture zero probabilityは2つの更新前Q15確率の凸結合。Q15は`floor(raw*32768+0.5)`を1..32767へclamp。観測後だけcomponent loss、mixture lossを加算し、primary/CTSはそれぞれ従来の更新を行う。switch rate、reset、prior/深さ/context/係数探索、事後fixed routingを追加しない。

各classのraw prequential mixture lossは独立閉形式 `min(Lprimary,Lcts)+1-log2(1+2^(-abs(Lprimary-Lcts)))` と照合する（累積浮動小数誤差許容1e-4 bits）。このreal-valued式と実Q15 loss/aux byte countは別に報告する。実aux range payloadは単回flushし、全class counts、component losses、有限loss、capacity、terminal状態を照合する。

alphabet表は0..256の33-byte bitmapと、昇順集合に対する元alphabet順序のLehmer/factoradic rank。kはbitmap popcount、1..257、sentinel0必須。rankはlittle-endian、固定幅は厳密整数 `ceil(bit_length(k!-1)/8)`（k=1は0 bytes）。bounded整数演算のみで≤257!、rank<k!、padding high7 bits zero、byte幅正準、重複なしを要求する。全257 symbolsではrank212 bytes、bitmap33、既存基本header36で281 bytes。encode→decode表の実byte一致とrank最小/最大、k≤6全順列、全257順列、異常入力をCLI診断で確認する。全payloadのdecoderはこの契約に含めない。

## E2Eと採否

新unit testなし。empty、低/高single、反復、周期、全byte域、固定seed mixedを2別process encode→通常frameの旧reference decodeで照合する。normal/probe primary frame byte一致、診断JSON決定性、component loss/countの旧CTS結果一致、metadata自己復元/正準拒否、hash locksを専用harnessで確認する。cfgなしnormalは既存28 checks/42 CLI、固定group SHA/11 entryを照合する。source/module/range/toolchain/全binary/harness/inputの前後SHAをreportへ保存する。

専用所有生成物基点は `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-packed-20260930/`。sourceはrejected research内の新moduleと最小cfg配線のみ。既存CTS componentの数値処理を変更しない。過去policy拒否の清掃対象は再試行しない。再現binary/report/fixturesは保持し、不要な新生成物だけ対象/ancestor/processを確認して清掃する。

実aux payload + 実packed alphabet metadata +36が483,599を超えればno-go。通過時もaux/full-frame同期decoder、CRC/no-clobber/異常入力、高速BWT、full encode/decode/peak memory、paired native-solid/カテゴリ/holdoutは別契約の未達条件であり、7-Zip超過とは呼ばない。通らない場合にprior/context/depth/候補のsweepへ変えない。
