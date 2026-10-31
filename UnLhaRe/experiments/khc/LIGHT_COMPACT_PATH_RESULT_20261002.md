# Light compact pathの数値/状態結果

新lightモデルは全履歴の木の位置対応と、旧モデルとの状態比較に合格。Prediction160B→24B、Node8Bは不変。full scheduler/codec組込み・wire・正式速度・総合7-Zip超えは未検証。

## 証拠と再現

- report: `../../build/khc-light-compact-path-20261002/report.json`、21048B、SHA256 `99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109F`。
- UTC 2026-10-01T20:10:27.4986333Z〜20:10:30.2046535Z、status `light_compact_path_state_verified_not_codec_or_timing`、7 checks / 9 compiler・audit CLI / 15 identities。
- compilerはrustc1.98.1、固定SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。Windows x64、Ryzen5 7640HS、PowerShell7.6.5。argv/CWD/実行環境はreportに保存。
- source `light-compact-path/light.rs`: SHA256 `42DAD8135AF86DF5AF0FDD6DCA6616C35346B5B127EF0B58751305B6B76BFDC4`。旧audit source `old_audit.rs`: `8A62D1F573A691D7CF599A240B3909A8B608C19771620CB09219CB7A1840E9AA`。verifier `verify.ps1`: `F7ACDB92677C2B36DB3FC1D93D641B661786121B8B08B713CA5335A8F1BE11AE`。

fresh出力ディレクトリで `light-compact-path/verify.ps1` をbundled pwshから実行する。一度作った出力を上書き/自動再試行しない。reportには4組の完全argvがあり、固定seedから入力を再生成する。大量の数値列を保存しない。

## 比較の範囲

opt2/opt3×overflow-check有無の4条件で全summary一致。各条件で:

- 全65536 history×17depthの1114112 mappingを、旧bitごとのheap recurrence、独立閉形式、実際の末端→親走査で直接比較。depth17/usize::MAXの2ケース拒否も一致。
- 7class・131072イベントでQ15予測と72値を直接比較。72値には全17pathのindex/zero/one/total、Q32予測、履歴、観測数、実選択depthを含む。selected depthはcfg専用TLSで実選択結果を取得し、診断fieldをPredictionへ加えていない。
- invalid class2ケース、stale1ケース、class mismatch1ケース、注入class cap1ケースを旧新比較。拒否前後の関係するpath snapshot不変を3ケースで検査し、その後の正常継続2イベントも一致。
- selected depth histogramはroot448件・depth16が97555件など、17depthすべてに観測があった。7classの比較回数もすべて正。
- fingerprint `d47b3bd91aab06f7` はmapping/通常状態を逐次計算した結果。拒否検証は別の実比較であり、このdigestだけで全拒否結果や同値を証明していない。

class capの注入は拒否境界の検査で、合法な学習によって562036803観測へ到達させたものではない。全node・全観測数・全入力列の総当たりではなく、対応式と初期/更新の不変条件を契約に記載し、有限状態列で実装を検証した。捏造したprivate countsへの旧式と同じエラー順まで保証しない。

## 変更内容と限界

Predictionの17個のusize配列を削除し、historyから末端位置を一度計算して親へたどる。Nodeはzero/oneをtotal/oneへ置き換え、expert選択のtotal加算を保存値読出しへ変更。zeroはchecked subtraction、更新はchecked加算。選択閾値32・全17nodeの学習・Q32/KT・class/stale/観測上限・leaf→root順は維持した。

旧sourceからの全文対応はold audit2件、新source10件（cfg appendを含む）。元の凍結light/KT/quotient、旧node-u32候補とterminal速度記録を変更していない。型サイズの85%削減はPredictionに限る。コンパイラによるcopy省略、総RSS、メモリ帯域、full CLI速度は未評価なので改善率へ読み替えない。

## 容量と次工程

生成物655416B（約640KiB）、4MiB予算内。report保存前budget634368Bとの違いはreport21048B。4小EXEとreportのみ、PDB/tmp/reparseなし。Cargo target/cache/raw traceを新設していない。source/compiler/proofに変更がないかを終了時に再照合する。

次工程は、凍結node-u32 codecのlight呼出しだけへこのモデルを別候補として接続し、既存7入力・4条件のframe/stdout/復元、双方向decode、破損/no-clobber/limits等を再検証する。既存state証拠は再利用し、重複numeric実行や大きなcacheは作らない。診断cfgを正式速度用EXEから外す。

固定483599B・574.5624ms未満・CPU15%・warmup1+測定9等は不変。旧terminalの自動再試行、確認待ちの初期化分離はしない。holdout/カテゴリ、同境界decode、四native決定性、製品/API組込みと安全性を残し、goalはactive。
