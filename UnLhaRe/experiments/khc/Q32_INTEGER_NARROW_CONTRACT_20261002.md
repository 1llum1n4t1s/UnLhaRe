# 整数refinementのu64中間化（実装前失敗計画）

前段の広いu128版は数値CLIに成功したが、通常path64命令・mulq6/imulq5の依存列だった。次はアルゴリズム/seed/2更新/1up/certificateを保ったまま、reciprocalをu64として扱う。速度採用・総合達成を意味しない。

前段の数学domainを維持する。power-of-twoを先にshiftで返すため、normalize後Dは2^31を除く[2^31,2^32)の非power-of-two。B=2^64の約数ではない。rは整数lower bound r≤floor(B/D)なのでD*r<B、u64積がoverflowしない。residual=0u64.wrapping_sub(D*r) は厳密にB-D*r。更新増分はu128(r)*u128(residual)>>64、r+増分≤floor(B/D)<2^33でu64内。最終n*rとcertificateはu128のまま。

失敗候補は、power-of-two guardを外す/順序を変える、D*r=Bのoverflow、wrapping差を一般のdomainへ流用、seed/bucket/商境界の変化、error優先変化。前段と同じ9,293,629件を各opt3/2で実行し、前段の全stdout summaryと一致することを必須にする。前段source/CLI/reportは固定SHAで保持し、明示置換からの全文対応を確認する。正常domainのfallback1件でも停止。

独立oracleは前段と同じ直接u128演算およびBigInteger14queriesであり、狭いhelperへ書き換えない。前段report `A956525D2234A000353B8E33E54BEB6B48C366A8CD64FF6F23E7B439B96EEFE2`、helper `7AF3AEC60ED2668A376DD7121F87F4B4232B91E2A686910E4DEDA15748BC7052`、CLI `60495ACFC85E6DC32ECAA2AB28BD31DB37F8E5904331617F0F1BAEAB1A7E7A6D`。

生成先は `build/khc-integer-refinement-narrow-20261002`、単独rustc標準ライブラリのみ。開始前・終了時256MiB予算を確認し、生record・全逆アセンブル・新Cargo targetを作らない。数値成功後に実EXEの通常経路が本当に狭くなったか確認する。静的命令数を実速度と読み替えない。完全codec同値と圧縮サイズ/全CLI速度の固定ゲートは別工程。
