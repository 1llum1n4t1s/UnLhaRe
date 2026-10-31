# u16 CDF 更新だけの private 候補

反証条件を先に固定する: 合法CDFで減算underflow/加算overflow、元usize式と差分、端点逸脱、頻度0、frame/payload差分が出れば不成立。parameter、文法、rate5、ctx3/8、wire、CRC、rANS、journal_growth_guardは旧候補から変更しない。

証明: 整数の厳密増加CDFは端点0/32768より i<=cdf[i]<=i+32512。q[i]=cdf[i]-i は0..32512の非減少列。prefixは v-=q>>5 なので減算量<=q<=v、suffixは v+=(32512-q)>>5 なので結果<=i+32512<=32767（i<=255）。u16の全中間演算が範囲内で、代数的に元usize式と完全一致する。q-floor(q/32)とq+floor((32512-q)/32)はともに非減少、境界はprefix(q)<=q<=suffix(q)なので更新後もq非減少、従って隣接CDF差>=1。端点は未更新で固定。

有限契約: finite_narrow_contract() は固定初期rowと64合法random rowの各256symbolを元usize oracleと完全比較し、端点/最小freqも検査する。randomは一つの固定xorshift seed（0x6d2b79f5）、内部qを0..32512から生成して昇順に並べ、端点を固定する。finite_contract()からも呼ぶ。#[test]・外部state・disk出力は追加しない。

仮説: u16中間と直接+=/-=で64bit幅の演算と冗長加算を避ける。LLVMのvectorizationと速度向上は未実測。親がcompile/run、元候補とのpayload/frame同一、full fee/速度を検証する。本担当はsourceのみ、費用0、既存モデル・RAM gate維持。所有はこのcodec.rs/PLAN.mdだけ、合計40KiB以内。
