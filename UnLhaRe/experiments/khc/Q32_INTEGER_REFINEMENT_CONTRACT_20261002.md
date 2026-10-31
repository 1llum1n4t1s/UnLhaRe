# Q32整数seed＋Newton補正の数値段階（実装前契約）

## 狙いと固定範囲

Q16構成は完全frame483600BでサイズNO-GOだったため調整しない。Q32の商・モデル・出力を変えず、可変posterior分母のDIVを整数乗算へ置き換えられるか調べる。本段階は単独CLIの数値成立確認であり、7-Zip超え・codec同値・実速度・採用を意味しない。サイズ上限483599B、単一thread全CLI encode median<574.5624msの固定ゲートは変更しない。

旧native32はx64 DIV、旧split/signedはf64推定と整数補正、KT tableは小さいcount分母の直接逆数。本仮説は可変分母をnormalizeした16bit seedから整数だけで2回精度を上げる。seed tableは32768×u64=262144B。新たなCargo target-dir、巨大raw、浮動小数、精度sweepを使わない。

## 実装前の失敗計画

| 失敗候補 | 判定と処置 |
| --- | --- |
| d0とchecked積overflowの優先の変化 | 独立u128積・直接除算のoracleとerror文字列を比較。1件でも不一致なら停止 |
| normalizeのshift/bucket境界、power-of-two、d=Q±1 | 全小分母、全32768bucketの代表3点×8shift、商境界±1、全u64のguard外をCLIで比較 |
| seed/refinementのoverflow、商不足2以上 | u128積、整数残余certificate、1upだけ使用。正常domainでfallbackがあれば成立失敗 |
| tableの長さ・初期化、構成間出力差 | bytes=262144を確認。opt3/opt2 CLIの件数・経路・rolling fingerprintを比較 |
| 有限標本だけで全入力を証明してしまう | 以下の数学domain証明と有限実行証拠を区別。既存modelの全state同値は主張しない |
| ディスク・メモリ・誤使用 | 出力は小さなstdout JSON、CLI内部で逐次比較、最初の失敗1件のみ。256MiB予算を開始前/終了時チェック。既存rootを上書きしない |
| コンパイラがDIVへ戻す/余計なwide算術を作る | 数値成立後に実machine codeを確認。速度は別の固定codec比較に進むまで主張しない |

再現入口: `experiments/khc/integer-refinement/verify.ps1`。固定rustc1.98.1 Windows x64 SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。数値CLI自体はRust標準ライブラリのみを使う。

## 数学domain（レビュー補足と親の導出）

Q=2^32、B=2^64、1≤d<Q、n=a*b<Q*d。s=leading_zeros(d)-32、D=d<<s∈[2^31,2^32)、i=D>>16∈[32768,65535]。r0=floor(2^48/(i+1))。r←r+floor(r*(B-D*r)/B)を2回、q0=floor(n*r/2^(64-s))。power-of-twoは直接shift、d=Qもshift32とする。

A=B/D、e=A-rとすると、r'=floor(A-e²/A)、0≤e'<1+e²/Aでlower boundを維持する。X=2^48とし、初期e0<X/[i(i+1)]+1、e0²/A<X/[i²(i+1)]+2/i+(i+1)/X<8。よってe1<9、e2<1+81/Q。商の実数差δ=n/d-n*r/2^(64-s)<(D/Q)*e2。

- D≤Q-81ならδ<(1-81/Q)(1+81/Q)<1。
- D=Q-k（1≤k≤80）ならr0=Q、第1更新r1=Q+k、第2増分floor((Q+k)*k²/Q²)=0。e2=k²/D、δ<k²/Q<1。

従ってq0≤floor(n/d)≤q0+1。1回だけup補正すれば商が一致する。残余certificate `q*d≤n && n-q*d<d` を必ず検査し、未成立は直接n/dにfallbackする（正常domainでfallbackなら本段階は失敗扱い）。r≤2^33、D*r≤2^64、refinement積/seed商積<2^97なのでu128内。補正後q<Qでq*dはu64内。

guard外は既存checked積/直接除算の正確さを維持する。これは全d/nのdomain証明であり、table初期化・実装・機械語の正しさは別途CLIで有限確認する。既存数学担当の追加読み取り確認を受けたが、新独立作者レビュー・実測速度の代替ではない。
