# symbol×recent追加expertの実装前失敗・独立検証計画

旧source/proof/contractを凍結し、新dirのみ編集する。変更は第五expert一つ（2^18rows）と5expert poolへの拡張。child数4とexpert数5を別定数・配列軸として扱う。

固定tolは数値2e-10*(1+absA+absB)、FD h1e-5/絶対差2e-6、集計bits絶対差1e-4。整数count/key/token/枝/grammarは完全一致。不一致後tol拡大・rate/uniform/clamp/grid変更・同条件retryをしない。

- 第五hashの係数/rotate/component/known rankContext/current symbol/causal recentを誤り得る。別式multiply/rotate/hash oracleへ全実測枝で照合し、symbol/node/context/recentの上限・invalid境界を拒否する。16bit causal stateはrun完了まで更新しない。別keyが同じmasked rowへ衝突する例を有界memory探索で見つけ、同tableのcount共有を実際に更新/照合する。
- 初期weights/軸混同を誤り得る。既存4weights=.25、第五0、child4/expert5の全配列形状を検査する。第五weight0から正gradientで学習、負gradientは下端0へclampするケースを検証する。
- score/softmax/uniform/gradient符号と係数/同snapshot/更新順を誤り得る。ln(count)・max差exp実装と別normalized ln(count/prefixTotal)・通常exp/sum oracle、別5count/weight配列で全枝probability/loss/5gradient/更新後weight/countを照合し、全gradient commit後counts更新を維持する。
- synthetic非対称5expertの内点weights、prefix1..4の全child×5中央差分50件でgradientを検査する。uniform/zero weights/forcedchild1（p1・gradient0・weights不変）、clamp両端、count初期/加算2/ceil-half/強制rescaleを診断内で検証する。
- topology/grammar/historyの移植間違いを検出する。全tree66049ケース・独立逆変換、node142ずつ/depth7、invalidprefix、rankContext0/8/invalid9、独立positions順位889227、oldflat1778454interval、別historyとcanonical両digestを継承する。
- 既存4expertの損失やcountが変わればpool比較無効。前logpool proofへrank/length8expert bits、oldflat component bits、grammar/枝/prefix/depth、既存cold/rescaleを照合する。新expert loss/cold/rescale、clamp/gradient件数/max差、前mixedとの差を有界JSONに保存する。
- 終端stateは別配列と全count/5weightを照合し、実配列shapeから値数を計算して予定4235776とも一致させる。digestだけで正確性を主張しない。Kahan component/全体和、NaN/inf/zero・範囲外weightを検査する。
- source/compiler/runtime/input/proof/importのpin変更/未知import、不在ファイル、既存root、child120秒/streams65536、EXE1MiB/report512KiB/8MiB超過を拒否する。parser/pin/readlock前後/容量preflightだけを先行し、親確認後opt2/overflowyesを一度compile/runする。未知失敗は最小有界証拠と親への報告で停止する。

fresh build/khc-quaternary-symbol-recent-opportunity-20261002内のEXE+JSONだけを保持し、予想300KiB未満。table/featureはmemoryのみ。frame/restore/rawtrace/Cargo/PDB/cacheを生成しない。disk guardは事前事後確認で強制quotaではない。

機会gateはmixed entropy+escape5936bits<3866504bits。偽なら不採用・整数wire/full/正式benchmarkを起動しない。真でも整数化/range丸め/実frame/速度/holdout/native/製品/APIは未検証、総合goalは未達。
