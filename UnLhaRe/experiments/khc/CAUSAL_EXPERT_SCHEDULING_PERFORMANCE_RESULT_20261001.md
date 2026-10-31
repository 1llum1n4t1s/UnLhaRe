# Causal scheduling: 正式測定は起動前quiet失敗

速度は未測定。2026-10-01T14:21:50.3988217Z開始、14:23:06.3464182Z終了、入口exit1。開始前5回のCPU10/8/0/7/7%は通過したが、支持proof読み込み後の `7zip/version/-1-before` は17%で15%上限を超過。7zaのversion呼び出し記録は作られたがexit/stdout/wallはいずれもnull/空で、childは起動されていない。warmup0、速度samples0、paired comparisonなし。外部processを原因と断定しない。

safe新rootに失敗reportを保存した: `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-causal-expert-scheduling-20261001\performance\report.json` SHA256 `A0F878078555F12655B534F3A35FC1EF04B12C89900A7D621F2D0EA60AB2328D`。エラーは `Host CPU busy; no ordinary performance adoption allowed.`。2104proof evidence filesと2308provenanceをreadlockし、終了後の長さ/SHA一致、さらに終了後現在値の再照合も差0。新旧proof/source/固定入力を保持し、サイズ483496B成功の前段結果を速度改善率へ換算しない。

実環境Windows10.0.26300/X64、Ryzen5 7640HS 6C12T、PowerShell7.6.5、rustc1.98.1/LLVM22.1.8、バランス電源設定。計測処理8functions不変、旧全文への18置換と106support pinsの事前対応確認はPREPARATION文書に保存。

performance root内14items（11native入力＋group＋directory＋report）、6646030Bを再現証拠として保持する。owned tmp/reparse0、cargo/rustc/7za/candidate/codec系の関連processなし。測定書庫/復号出力はまだ存在せず、ここで不要な大型入力は生成していない。閾値緩和、優先度/affinity/power変更、他processへの介入、自動再試行をしていない。

通常causal schedulerはcorrectness/size候補として保持するが速度採用は保留。次は同じ試行を再起動せず、heavy内部の17深度混合そのものを疎な幾何深度階層へ変える別アルゴリズム仮説を先にサイズで反証する。固定開発ゲート・holdout/category・同境界decode/資源・4native/製品/安全性の総合goalは未達のまま。
