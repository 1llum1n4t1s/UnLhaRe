# causal direct mix：初回compile失敗、native未実行

初回rustcはprobe.rs:25のprintln!出力末尾に余分な閉じ括弧1個があり、unexpected closing delimiterで失敗。EXE未生成、native/E2E/loss/terminal全row検証は未実行。モデルのサイズ条件を評価した結果ではない。

原因は末尾 `plain.capacity()));` が `plain.capacity());` であるべきwrapper構文。数値式/更新政策の変更が必要な原因ではないが、今回一compile/native・初回失敗保持/親判断の契約に従い、source修復や同条件再compileはまだ行っていない。追加実行には親が修復と別未使用出力への追加compileを判断する必要がある。既存失敗reportは上書きしない。

failure-first、Fenwick/mixture/hand E2E/probe/runnerを新rootへ保存した。frozen features履歴を読み取り再利用、四key再構成、独立dense oracle4194306prefix/手製524CDFinterval等は定義済みだが動的成功と呼ばない。モデルファイル自体もまだ全型検査完了ではなく、構文修復後に別問題が残る可能性を排除できていない。

実行前capacity見積りで当初mix phase60000000Bは不足と担当/親の算術照合が一致。leaf/tree/total/first-key/collision/bitmap/weights39577184B＋run12582912B＋input2811006B＋hist余裕1369112B＋4MiB=60534518B。親最終plan SHA A7D8FBD4C5BDEFFFD77511946B53BCE245AE17C9533BA70059D15B901253B5CCへ再読/pinし、64MiB=67108864へ事前worstだけ訂正した。固定160MiB契約、モデル/設定は変えず、測定結果を見たパラメータ変更・有利な再試行ではない。BWT別phase141598926B推定、peak未実測。

初回compile1回218.0581ms（60s以内）、version照会225.6735ms、native0回。rustc1.98.1/edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/frame_audit/primitive_audit一設定。newsource closure8file/7edges/43498B、source300KiB以内。凍結static source19とfeature diagnostic source7をlive照合した。source8＋identity39の47 beforeafter/live pin pairsはこの失敗保存時点で不一致0。

生成物はbuild/khc-causal-direct-mix-20261004/report.jsonだけ46002B、SHA193939C7A911AA00F309AC79DA371E386FF5BF16623A530179B00676C5CAFB95、8MiB/report256KiB以内。compile stderrはbounded childの16KiB以内に保持。EXE/PDB/Cargo target/raw trace/frame/plain/input copyなし。失敗report保存後readonly disk guard/process0を確認する。旧root/source/report/plan/EXEの変更、Git/stage/commit/push、外部write、削除、製品/x86/version変更なし。

`pwsh -NoProfile -File UnLhaRe/experiments/khc/causal-direct-mix/verify-failure.ps1` は失敗証拠のSHA/全pins/容量/未実行範囲を読み取りだけで検証する。成功診断のverify-artifactsとは別物。修復sourceへの移管後は元失敗pinsのlive不一致を隠さずhistorical扱いする必要がある。

残作業はwrapper構文修復→明示許可された追加compile→native E2E/一入力loss→成功時RESULT/readonly verifier/最終guard。f64 floor portable wire/実codec復元/速度/4native/新context独立監査は未実施。担当source編集を停止して親判断へ返す。
