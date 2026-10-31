# categorical CTS・5特徴整数poolの全入力診断結果

整数仕様の独立比較と全入力の固定CDF entropy機会gateが成功した。CDF entropy 3788636.714502990bits＋共通escape5936bits＝3794572.714502990bitsで、予算3866504bitsより71931.285497010bits（8991.410687byte相当）少ない。これは実書庫サイズや速度の成功ではなく、7-Zip総合超えのgoalは未達・activeのまま。

## 数値・因果順序・状態の検証

Q48のcanonical ln/exp LUTからQ32 featuresを作り、count4＋CTS1の5特徴poolを整数演算で予測・学習する。観測childを受け取らない予測からHamilton CDF32768を確定し、同snapshotの5勾配・次weightを準備する。CTSは凍結Q32 sourceをimportした。encoder用のmath/pool/CTS kernelはf64を使わない。f64は診断内の理想局所比較とentropy集計に限定した。

| 比較 | 実測・件数 | 事前上限 |
| --- | --- | --- |
| canonical ln | 114806件、最大局所誤差7.636700161128829e-9 | 2e-8 |
| canonical exp | 32769件＋端点/cutoff5件、最大局所誤差3.351145805297051e-9 | 2e-8 |
| softmax q | 全3825340枝、最大絶対差3.614946730845503e-9、bound比0.212852557097984 | 各childで1e-6×理想確率＋8/Q |
| uniform混合P | 最大絶対差3.678695126296816e-9 | 2e-6 |
| gradient | 全19126700値、最大局所差3.5164107426946534e-5 | 2e-3 |
| 一更新後weight | 最大局所差1.3736707060729714e-7 | 1e-5 |

L/E各4097値とcount LUT全値を別起動計算にexact比較した。小math/pool診断のoracleには128-step binary long divisionと別Hamilton rankingを使った。CTS・全入力oracleは別halfcounts/history/path/weightsとnative u128の別式であり、当診断でCTSまでbinary divisionを使ったとは主張しない。先行CTS primitiveの別proofは契約から参照している。理想real比較は同じ整数snapshotへの局所比較だけで、独立f64連続軌跡との同値性ではない。旧f64 tol2e-10と新近似の上限を混同せず、実行後に条件を緩和していない。

内点10 prediction・理想real gradientの中央差分50件、edge244・専用fixture3を含む局所257 prediction、math非法15・pool非法8・全state非mutationを伴うbranch拒否5件が成功した。親と別read-only担当の実行前確認でrare q=0ケースの独立比較不足を見つけ、全4childのexact/局所real比較、factor/gradient0とweight不変を実行前に追加した。親BigInt fixture、初期CTS weight0からの学習、負clamp、uniform、forcedprefix1も確認した。

全3825340枝でCTS各9levelのraw/weight/KT/mixed/rawmass、pool/CDF/5gradient/delta/次weightsを独立oracleへexact比較した。終端5808642値（旧table＋pool3187200、CTS2621442）も全値を比較した。state_digest 9128444225deabceはbase table/poolのみのdigestで、CTSも含む全状態hashとは主張しない。全状態の保証は直接比較による。

grammar双方58735a2b7383d755、全tree66049、独立rank889227、oldflat interval1778454、rank2725772/length1099568枝が一致した。凍結f64 proofとの既存4expertの8component損失、cold/rescale、prefix/depth、CTS causal query/cold件数もrunnerで照合した。

## 圧縮量の機会gateと限界

- CDF entropyはrank2698058.0593391885/length1090578.6551638017bits。Q32 P entropyは合計3788637.946353319bits、escape込み3794573.946353319bitsで別記録した。primary gateにはPではなくCDFを使った。
- 先行f64のescape込み3794574.025516505bitsとの差は1.311013515bitsのみ。整数化で主要な改善余地を保持した結果であり、この微小差を新たな圧縮性能向上や実byte差として宣伝しない。
- 固定483599byte frame・574.5624ms・CPU15%等の総合条件は維持する。整数range coder/canonical終端/実frame/encode-decode E2E、正式速度・CPU、holdout/categories、4native、製品/API統合は未検証。full_benchmark_allowed=false。
- 次は通過済み整数仕様で実frameとdecode再現を検証する。機会gateだけで製品へ採用しない。研究内部のpublic Prediction helperは任意改変snapshotの完全整合再検算を提供しないため、外部API保証にも転用しない。

## 実行・識別・容量

親の最終source/runnerレビューと非実行preflight後、one opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONEを一度だけcompile/runした。rustc1.98.1・bundled pwsh7.6.5、3childはexit0・stderr空。compile2876.239ms、診断CLI24483.2248msで120秒上限内。CLI時間はoracle・局所real・勾配・全状態照合込みの単発診断なので、正式encode/decode速度に使わない。

22source/contract/oldproof/compiler/runtime/input/guardと6source/5import edgeをpin/readlockし、EXE事前identityとparsed auditをvalidator前に永続化した。bound scalar式は非実行preflightでも評価した。親は22before/22after＋EXE before/afterを再hashして差異0、22sourceが親の実行前preflightとも一致することを確認した。旧failed wrapperの不足をこの結果に引き継いでいない。今回のwrapperもpassed。

保存先 `build/khc-quaternary-cts-integer-pool-opportunity-20261002/`:

- `opportunity-o2-yes.exe` 331776byte、SHA71C4A909212D2358AFBD66CD7DC22FCE3A6B138AF3444F82B643B7F0C68BEA2D。
- `report.json` 29109byte、SHAA0A586A487E8761E075CD3B157866CD5C0183AEC94106D9E6556199688C11A01。
- 合計360885byte（約352KiB）、2file、予想512KiB・8MiB cap内。容量guardは事前/事後確認で、OSの強制write quotaではない。親が所有EXE残存process0を確認した。Cargo/PDB/cache/frame/restore/rawtrace/table出力を作らず、入力も複製しなかった。用途終了の一時物なし。上記2fileは再現証拠として保持する。

contract EE130558C966D6C96DE8887050A01D39FA3FDC59802AC70A867BC0DD53BE28FA、fixed_math A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD、integer_pool 7135CC9E6F5CF57191DC6EE409D8C32C8EF9FEB9C1B6B2D7B18C7B436F56C625、opportunity 5DEC4BD1AAAC58BEFB8F933CD5A2EB48D82CC911DAA9C631B044C3F00631003F、runner 18251833ED8FEECBB89E95BD563B5002FDC454F5B05780359439345C5AAAD3A7、失敗計画7B982332B80124B73599E594FA20FB9755AAA23BDBF427BD31F5A55DB94C5273。旧source/proof/root・Git stage/commit/push・version/公開・x86・共有cacheは変更しない。
