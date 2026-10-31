# exp_neg inverse-scale：先行finite失敗契約

親PLAN SHA0F001B32AE8B7763BB656BC1F0D6F19D5A02EDB04E6EFFFA3F4F0CACB3B8464Aを全文確認。所有3files、本書→scaled_math.rs→probe.rsの順に保存。compile/native0、親レビュー・停止READY後に親単回実行。旧source/証拠/製品/APIは全凍結。

## 数値変更契約

旧float_math SHA9349A09F011C051CBD3EB7927DAE509035EE86F2993991194536B7166C52F7F3、canonical fixed_math SHAA599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACDを直接参照。コピーの `let result=interpolation/(1u64<<exponent) as f64;` 1箇所だけを `let result=interpolation*f64::from_bits((1023u64-u64::from(exponent))<<52);` へ。exponent>=32 cutoffの後だけbit構築し、guard/error/cutoff/補間/加算順/ln_count/ln_cts/new/Vec allocationは全本文復元で不変と示す。追加表/heapなしはsource証拠のみ、実allocationや速度の証明ではない。

## 先に固定したcase一覧

旧新Mathを各1生成、case配列Vec0・時系列保存0、逐次全Result比較。指数0..31、index0..4096、`d=exponent*ln2+index*(ln2/4096)`。各dのnext_down/center/next_upの順に32×4097×3＝393312 grid cases。LN2はcanonical定数を旧newと同じ式でf64化する。

randomはLCG seed0x6d2b79f5、更新 `seed=seed*1664525+1013904223 mod2^32`、`d=f64(seed)*(128/f64(u32MAX))` の65536件。乱数seed/演算順を変更しない。

boundary raw24件の順序を固定：

```
0000000000000000 8000000000000000
0000000000000001 000fffffffffffff 0010000000000000
8000000000000001 800fffffffffffff 8010000000000000
7ff0000000000000 fff0000000000000
7ff8000000000000 fff8000000000000
7ff8000000000001 fff8000000000001
7fffffffffffffff ffffffffffffffff
7ff0000000000001 fff0000000000001
3ff0000000000000 bff0000000000000
7fefffffffffffff ffefffffffffffff
4060000000000000 c060000000000000
```

さらに128.0、32.0*ln2の各next_down/center/next_up6件。boundary30、総393312+65536+30＝458878。重複中心は意図的、dedupしない。各groupと総数<=500000を検査する。signed zero/NaN payload/±Inf/subnormal/domain外/128近傍/cutoff近傍を含むがf64全域証明や4native互換の代替ではない。

Okは全to_bits、Errは全文字列、Ok/Err分類を直接逐次比較し、違いは最初のgroup/ordinal/inputbits/両Resultでbounded failureとする。Ok/error合計＝total、mismatches0、exact_result_comparisons＝458878を検査。constructor failureは保存して先へ進まない。ln/new不変はsource復元で確認し、別ln実行を今回case数へ混ぜない。

results_digestは16hexの順序付きchecked u64 checksum。input/result/class/errorbytesを16bit fold（XOR/rotateのみ）し、ordinal×foldをchecked multiply/add。最大500000²×65535＝16383750000000000<2^64。counter/digest overflowやcase上限超過は失敗。checksumは衝突耐性SHAでなく表示証拠、全Result直接比較の代用品ではない。

## 反証・資源・未検証

source/SHA/全文復元1site残差、追加module/heap/式順、constructor失敗、Okbits/分類/Err順・文字列、非finite/境界差、counter/digest overflow、無制限Vec、compile/panic/timeout/保存/容量超過を拒否。wrapper `reference_exp/candidate_exp` は各1、unsafe(no_mangle)/inline(never)、Rust ABI。LLVMが既に同じ命令なら命令削減根拠は棄却。asm差だけで通常codec速度を主張しない。

source＋PLAN64KiB、EXE1MiB/asm2MiB/report256KiB/output8MiB/空き5GiB。constructor2個の既存表だけでcase保存なし。heapの追加が無いというsource主張とallocator実測を区別。親runnerがbefore/after/live pinsと予算を扱う。本人は非書込構文/全文復元のみでcompile/native0。固定codec/fullframe/Proof/破損/通常速度は今回未実行、正式GOALは未達・active。Git/version/API/product/x86/external/delete/追加委任0。
