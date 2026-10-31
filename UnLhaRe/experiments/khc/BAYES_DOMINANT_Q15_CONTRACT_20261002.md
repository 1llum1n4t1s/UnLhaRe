# Bayes Q15優勢component shortcut: 実装前の失敗計画

対象は研究用KHBSCH01 codecのみ。製品、版、固定ゲート、元の凍結source/proofは変更しない。7-Zip総合超えの達成を意味しない。

## 一つの仮説と反証

`Class::predict`は現在毎回exp2/logistic/float混合を実行する。log2は既に32768個の表なので、log2未最適化という仮説は棄却した。Q15の丸め後に同じ整数となる領域で混合を省ける、という一つの仮説だけを試す。閾値sweepはしない。

component bounds検査は先行させる。両lossと差が有限のときのみ、component同値、またはloss差の絶対値32以上で優勢componentを直接zeroへ返す。差primary-cts>=32はcts優勢、<=-32はprimary優勢。Predictionのprimary/ctsを元の値で保持し、loss更新、gain、schedulerを変更しない。負の有限lossを新たに拒否しない。NaN/Inf、有限同士の差のoverflowは旧経路に残す。

実数モデルで少数側重みは1/(1+2^32)以下、CDF差は32766/(1+2^32)<7.63e-6。整数中心からfloor(x+0.5)の境界まで約0.499992残る。component同値なら実数混合は元の整数CDFそのもの。これは理想実数の証明であり、Rust exp2の全native厳密精度保証ではない。実際の指定Windows x64/rustc1.98.1で旧コードと直接比較し、四native未検証は残す。

## 失敗を先に列挙

1. 優勢方向/丸め/32境界を誤る。全32767のprimary値と端点・中央・隣接のcts値、差32の前後、符号、同component、seed付き独立値を旧実際のpredictと逐次比較する。
2. bounds拒否やNaN/Inf挙動を変える。0/32768/65535のcomponent、±0/負有限/最大有限/差overflow/±Inf/NaNを成功値とエラー文字列の双方で比較する。
3. zeroだけ一致して学習入力を失う。監査hookはPredictionの三値を返し、全て比較する。full codecでschedule stdout全体/完全frame/復元を旧候補と比較する。
4. 監査時だけ異なる実装を使う。旧/新moduleは本文を凍結sourceから明示置換で再構成し、cfg監査hookの追加以外も全文照合する。normal codecでは監査hookは無効。
5. optimization/overflow差。数値CLI opt2/opt3+overflow-checks=yes、full codec通常/checkedを実行し、独立旧予測との全件比較と要約一致を要求する。
6. wire/安全性回帰。既存7入力、双方向decoder互換、CRC/切断/余剰/magic拒否、no-clobber、入力不足、完全483496B固定frameをE2Eで確認する。ユニットテストは新設しない。
7. source/EXE/入力取り違え。compiler/旧proof/依存/source/new EXEを読取lockとSHA前後で保持。新ディレクトリ一回のみ、既存出力上書きや自動再試行なし。
8. 容量増大。numeric生成先は8MiB、full E2Eは32MiB予算。既存固定入力/旧frame/EXE再利用、Cargo target新設なし、raw数値/traceなし。生成前後capacity guard、有限JSON/失敗先頭一件のみ、120秒child制限。必要証拠を保持し用途済み一時物だけ安全に削除。
9. 出力同値でも速度が向上しない。正確さ合格は採用ではない。正式比較は新source/binary/proofを固定した後の一回、warmup1+9/circular/静穏CPU15%/完全CLI境界/483599B/574.5624msを維持する。前回CPU16%停止の旧試行は再開しない。

## 出力と終了条件

数値reportは実際の逐次照合件数、branch適用件数、bounded witness、全CLI argv/exit/要約、source/EXE SHA、容量を持つ。全件生値は保持しない。数学的同値、指定native有限検証、性能採用、四native/holdout/製品統合を分ける。反例ならshortcut不採用、元sourceを保持し次の仮説へ移る。
