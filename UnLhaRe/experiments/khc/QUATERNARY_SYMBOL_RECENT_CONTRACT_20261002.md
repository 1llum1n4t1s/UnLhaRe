# logpoolにsymbol×recent予測を追加する機会診断: 実装前契約

## 根拠・反証条件

凍結logpool report D84D70C2D64A366C073DEC83E5019DF24C6B34F4538B48435284DEC914C7A320では算術pool比16585.968249byte相当改善したが、固定payload予算まで34904.527234byte相当不足。poolの改良だけで成功したとは判断しない。次は既存symbol/recent予測の組合せを条件付けする5番目のexpertを一つだけ追加する。既存4expertはcurrent symbolとrecentを同時に条件とするtableを持たない。新expertが情報を加えなければ固定機会gateは未達になり、不採用・整数wire/full/正式benchmarkは起動しない。

既存候補の測定再試行、parameter grid、条件/size/CPU/holdoutゲートの緩和をしない。新しい固定候補は機会診断のみであり、製品の公開仕様や旧wireは変更しない。

## 固定変更範囲

新source dir quaternary-symbol-recent/、fresh output build/khc-quaternary-symbol-recent-opportunity-20261002。前logpool source 09A858DA1FD1C712D548D53AA580747CF68B74266419A4E1419369961E3B5C6Dとrunner/plan/proofは凍結する。

topology、alphabet256/257、142node/maxdepth7、合法prefix1..4、rank/length sideinfo、canonical grammar、causal history、half-count/rescale、old flat、既存4expertのrow/hash/count/updateをそのまま継承する。child数4とexpert数5を混同しない。

5番目expertは separate table 2^18 rows、各row [1;4]のhalf-count初期値・観測child+2・total32768でceil-halfという既存count規則を用いる。row indexは

`hash(nodeKey ^ (symbol as u32).wrapping_mul(0xc2b2ae35) ^ recent.rotate_left(7)) & ((1<<18)-1)`

nodeKeyは前と同じcomponent/rankContext/nodeである。symbolはcurrent runの既知symbol、recentはrun完了前の16bit causal履歴。rank/lengthの途中で履歴を変えず、未来のrank/length/next位置を新keyへ含めない。hash collisionは既存と同様に意図的な共有で、hash mask/grid/table増設はしない。

poolは前のln(count) score、max差exp、uniform1/4096、rate1/256、clamp[0,2]をexpert数5に拡張する。global row4608ごとのweightsは既存4つ0.25、新expertだけ0.0に初期化する。新expertの非一様な情報が学習されるまで既存poolの初期強度を変えないためであり、本候補では固定する。5gradientを同じcount/weight/prediction snapshotから同時算出・commitし、後で5tableのcountsを更新する。旧weights/stateの一致は要求しないが、既存4table/count/lossは完全に同じ履歴でなければ比較無効。

## 独立検証と判定

コード前にFAILURE_PLANを保存する。数値tol2e-10*(1+absA+absB)、FD step1e-5/abs2e-6、集計bits abs1e-4を継承・固定し、不一致後に広げない。別normalized ln(count/prefixTotal) oracle、別5count/weight配列で全実測枝の確率/loss/5gradient/更新weight/countと終端を照合する。新hashは別式rotate/multiply/hash oracleへ照合する。

synthetic非対称counts/weights/prefix1..4の全child×5gradientを中央差分（50件）で確認。新expert weight0から正方向に学習できる場合と、負方向が下端0で止まる場合を検証する。uniform、forcedchild1、clamp両端、invalid境界、rescale、hash衝突共有も確認する。前のtree66049件・独立rank889227件・old flat1778454件・両grammar digestを継承する。

report bits orderは mixed/global/symbol/recent/joint/symbol_recent。既存4expertのrank/length損失8件、oldflat component損失、branch/prefix/depth/grammar、既存4tableのcold/rescaleを前logpool proofへ照合する。新expertのloss/cold/rescale、clamp/gradient件数/最大差、前logpool mixedとの差を保存する。5table+5weightの終端state値は4235776件を予定し、件数を実際の配列形状から独立検算する。

固定機会gateは mixed entropy + 共通escape5936bits <3866504bits。偽なら候補を不採用にする。真でも整数化・range丸め・実サイズ・速度・holdout/native/製品は未証明で、元の総合goalの条件を縮小しない。

## 実行と容量

1opt2/overflowyes EXE+小JSONのみ、fresh8MiB cap、予想300KiB未満、EXE1MiB/report512KiB予約、child120sec/stdoutstderr65536、debuginfo0 /DEBUG:NONE。追加tableとoracleはメモリにだけ保持し、rawfeatures/table/traces/frame/restore/Cargo/PDB/cacheは作らない。disk guardは事前事後確認であり強制write quotaではない。

rustc1.98.1・bundledpwsh7.6.5、source/import/compiler/runtime/input/proofをpin/readlock/前後hash照合。parser/pin/import/preflight、親の最終source/hash確認後にcompile/runを一度だけ実行する。既存root上書き・同条件retry・未知失敗後tol変更は禁止。全旧証拠保持。Git stage/commit/push/version/公開/外部書込/x86/共有cacheを対象に含めない。
