# signed商推定の支持範囲

対象は研究用Q32商helperだけ。モデル値/出力を近似化せず、guess算出方法を選び、同じchecked整数certificateで正確性を保証する。

## 観測とローカル導出

前候補の生成コード診断は、KT/alphaにもu64入力の分割float変換とu64出力の二重cvttsd2si等が残ることを示した。これは時間占有率のprofileではなく削減対象の静的証拠。

`causal-bayes-q32-corrected-lut-inline/cts_model.rs` のcapとchecked totalから0<=zero<=total<=562036803。従ってKT分子の最大は

`2^31*(2*562036803+1) = 2413929690180878336 < 2^62 < i64::MAX`。

alpha分子はQ=4294967296。posterior分子の許容最大 `Q*(Q-1) = 18446744069414584320` はsignedMAX9223372036854775807を超える。posteriorを無条件signed化する設計は却下する。

元CTSは各予測bitにKT17、posterior16、alpha1の可変分母ratio式がある。少なくともKT17+alpha1はsigned分子範囲で、34式中18式を新枝の対象にできる。これはsource上の式と数値境界の話であり、動的fallback頻度・機械語DIV数・全CPU時間の52.94%という意味ではない。

## 正確性の理由

1. 前段がd=0を拒否、a*bのoverflowを拒否する。d==Q/d>Q経路は変更しない。
2. 残るdは1..Q-1。n<=signedMAXの枝でn as i64は非負を正確に保持し、n/dのfloatは非負・finite。n>MAXでは旧推定式を維持する。
3. [Rustのnumeric cast仕様](https://doc.rust-lang.org/reference/expressions/operator-expr.html#numeric-cast)はinteger-to-floatのnearest ties-to-even、float-to-integerのゼロ方向丸め・範囲外飽和を定める。n=MAX近傍でf64が2^63になる場合もas i64はMAXへ飽和する。負のguessをu64へwrapする経路ではない。
4. guessが正解より上下にずれていても、checked product<=nかつn-product<dを満たすguessだけを返す。これは整数の除算定理によりfloor(n/d)に一意。失敗時は旧native n/dへ戻す。

従って任意の成功入力の商の正確性はfloatの誤差幅や「一度で補正できる」ことへ依存しない。変更でdown/up/fallback等flagsの頻度が変わることは正常であり、商だけを旧oracleと照合する。unsafeのunchecked castや範囲外のsigned整数演算を使わない。

性能は未判定。range branchの追加、signed castの飽和処理、コードサイズが削減を相殺し得る。numeric E2E/独立監査が成功してからcodecへ入り、全frame一致と元固定の正常比較を実施する。総合目標は7-Zip超過のまま、現在は未達。
