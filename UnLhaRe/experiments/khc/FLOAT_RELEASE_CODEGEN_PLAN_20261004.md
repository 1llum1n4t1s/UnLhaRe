# 通常Release由来codegenの限定screen

## ローカル根拠

Cargo.toml:47-50の製品Releaseはthin LTO、codegen-units=1、panic=unwind。一方、lookup-float/FT1単体診断はopt2、LTO/CGU未指定、panic=abortだった。FT1の全frame478750B/全plain/Proof14/stats一致と拒否非mutationは成功。一周ABBAの圧縮13.16749%・展開0.99407%短縮はばらつきを含む内部診断で、製品採用/正式改善ではない。

現在の数秒という内部値を通常Releaseの速度と同一視せず、次に一つだけRelease由来の設定で同じソースを検証する。parameter/depth/数値方式のsweepではなく、配布設定との測定境界の差を調べる。変更はcompiler設定のみでalgorithm/sourceを改変しない。

## 実装前の失敗条件

別ソースのcompile、凍結source改変、source/tool/inputのpin差、薄いLTOで数値bits/frameが変わる、panic方式差による拒否経路の欠落、通常Releaseと診断cfg/overflow条件の違いを隠す、過去時間との単純比較を正式改善率と呼ぶ、compile/native timeout、report/EXE/生成物容量超過、生frame/input/plain生成、失敗report上書き、有利な再試行。

## 固定実行契約

- 新規 `float-release-codegen/` はrunner/結論のみ。凍結 `float-fresh-transaction/` のprobeと全19sourceを直接compileして参照する。元entry runnerは実行しない。
- rustc1.98.1 Windows x64、edition2024、opt3、lto=thin、codegen-units=1、panic=unwind、overflow-checks=yes、debuginfo0、DEBUG:NONE、frame_audit/primitive_audit。overflowyesと診断cfgがあるため製品Releaseそのものではなく「Release由来codegen」と明記する。
- 既存fresh拒否20・standalone正常14/異常33/checked26、5case全frame/plain/typed Proof14/stats、固定478750B同値を新EXEで確認する。最適化設定間のfloat軌跡を一般に保証せず、実行した入力での全bits比較と区別する。
- 合格後に同じ新EXE内のreference/fresh/fresh/referenceを一周だけ実行する。新binary内のアルゴリズム差は診断可能だが、旧opt2 reportとの時間差は別実行・別compileなので記述比較のみ。正式なcodegen効果率/7-Zip勝利へ読み替えない。
- 出力 `build/khc-float-release-codegen-20261004` は未使用必須。8MiB全生成、EXE1MiB/report256KiB/source閉包300KiB、stdout64KiB/stderr16KiB、compile60秒/native各120秒。rustc単体、新Cargo target/PDB/rawtrace/frame/plain/input disk copyなし。
- source/tool/input/Cargo.toml/plan/元FT1report/EXE/runnerを実行前後pin。disk-budget事前/事後/最終report後、owned process終了を確認。元証拠の削除/上書き、Git操作、外部書込み、製品/別版改変をしない。

## 判断

正当性が崩れたら不採用で原因を切り分け、設定を勝手に緩和しない。数秒のままなら大きい正式比較へ進めず、処理回数/中間データを減らす構造候補へ戻る。十分に近づいても元の静穏full CLI・固定size/decode/resource gates・holdout/category・完成書庫・4native・製品APIの全条件は別途必要。GOAL activeのまま。

Performance/Tester/Hardeningは今回の測定境界と同値、Normalizerは既存配布設定への対応付け、Modernizer/Cleaner/Async/Intelはdependency/削除/並列/外部仕様を変えないため非該当。parentが採否、runner編集担当一名。前FT1sourceの編集停止・結果回収後に実行する。
