# Q32 商推定の成立範囲と反例

独立した読み取り専用調査を親が照合。性能・採用判断ではない。

## ローカル数値経路

凍結 `causal-bayes-q32/cts_model.rs` のKTではd=total+1<=562036804、N=(Q/2)(2zero+1)、真のN/d<Q。posteriorではS=w*pk+(Q-w)*child、d=ceil(S/Q)<=Q-1、N=w*pk<=S<=Qdなのでfloor(N/d)<=Q。alphaはN=Q、2<=d<=562036804。retained更新のd=Qは従来通り整数shiftを保持できる。Q=2^32。

## 推定の誤差と落とし穴

1<=d<=Q、floor(N/d)<=Qならx=N/d<Q+1。binary64のunit roundoff u=2^-53に対してdの変換は厳密、整数変換と通常除算のround-to-nearestで |y-x|<=x(2u+u^2)<9.54e-7<1。非負のfloat→u64 castは切捨てなので推定商は真の商±1以内。

- N=u64::MAX-1=Q^2-2、d=Q-1では真の商Qだが推定商Q+1。推定商<=Qという検査は成立しない。
- N=u64::MAX、d=Qでは推定商Qとなり、推定積Q^2がoverflowする。d=Qのshift経路はこの問題を回避する。
- 指定領域でd<Qなら推定商<=Q+1、推定積<=(Q+1)(Q-1)=u64::MAX。域外では±1を保証しない。
- checked積失敗、補正後も積>N、残余>=dのままなら元整数除算へfallbackする。補正途中の未検査減算・加算を許可しない。

## 誤差保証に依存しない返却条件

checked整数積p=q*dについてp<=NかつN-p<dを確認した場合、ユークリッド除法の一意性でqは厳密なfloor(N/d)。この証明を通らない場合はN/dに戻す。そのため、推定の品質はfallback頻度と速度に影響するが、返却するモデル数値の正しさを左右しない。分母0とchecked積overflowは元のratioと同じ順序でerror。

## 外部仕様と未検証

[Rust Reference](https://doc.rust-lang.org/reference/expressions/operator-expr.html#numeric-cast)は整数→floatのnearest/ties-evenとfloat→整数のtoward-zeroを定義する。[f64公式文書](https://doc.rust-lang.org/std/primitive.f64.html)はbinary64を説明し詳細をf32へ参照する。[f32公式文書](https://doc.rust-lang.org/std/primitive.f32.html)は通常の加減乗除がroundTiesToEvenと明記する。上の誤差不等式はこれらからの数学的推論であり、ライブラリのexp2/log2精度保証とは区別する。algebraic_divやfast-mathを使用しない。

独立調査はソース1本と公式資料2件に限定。親は追加で公式f32記述を確認した。4対象環境のネイティブ実行・全CTS状態・全frame・速度は未検証。数値E2Eを先行し、成功時も即座に採用としない。
