# 次の hotpath：読み取り調査の採否

総合ゲートは維持し、現在 Model3-lazy の通常実行を先に測る。調査担当 `/root/float_gap_causal_audit` は読み取りのみ、編集・compile・native・外部操作0で完了。要求/役割の実効profileは analyst / gpt-6.1-sol / medium。

## P-EXP-SCALE：候補、未採用

`lookup-float-cts/float_math.rs:30–40` の exp_neg は指数0..31の補間値を動的2冪で除算する。正確な逆2冪係数の乗算なら追加heapなし。poolから合法childごとに呼ばれる。固定合法interval14305969/方向は source上の呼出し機会であり実命令数ではない。

数値domain/cutoff/grid/補間順/拒否文字列を維持し、旧新結果bitsと拒否を指数0..31・grid/ln2境界前後・cutoff・非有限値で比較する必要がある。LLVMが既に最適化している可能性もあり、生成命令と通常実行の効果は未測定。1式の改善で総合速度を満たすと主張しない。

## P-FRESH-HARDCUT：候補、計測前に実装しない

`causal-hard-cut-wire/codec.rs:145–151` の予測と観測の間ではModelは変化しない。しかし `lookup-float-cts/model.rs:81–83` は4行/weight/serial、`hard-cut-lazy-errors/lazy_engine.rs:35–36` はpath・6node・raw総和を再照合する。

排他的 transaction なら source上は方向ごと15301360行比較・22952040node比較・3825340path再計算の削減候補。Snapshot240B×3825340はソースpayload規模のみ、実メモリ転送とは断言しない。6nodeごとの価格の分母・分子は異なるので共通価格にできない。

旧 `float-fresh-transaction/RESULT_20261004.md` は旧CTS/opt2/計測cfgでABBA圧縮−13.167%、展開−0.994%（ばらつきの可能性）。現在hardcutへ効果を一般化しない。失敗atomicityとchecked overflow/CAP、coder選択→edge→pool/count/audit準備→全6node準備→commit順を守る先行E2Eが必要。

## 次の判断

Model3-lazy通常値の確認後に、現hardcutの CTS predict+observe / pool predict+observe / 残りModel・coder・BWT/inverse の三bucketを限定sampleで測る。旧CTS68%を現在の内訳と呼ばない。計測版の全frame/plain/Proof14/34破損検証と、非計測版の正式速度を分離する。

static方式の既往を再実装しない。class2/5限定MDLは費用込み494389Bで上限483599Bを10790B超えた。無料モデルの楽観値473039Bは採用根拠ではない。
