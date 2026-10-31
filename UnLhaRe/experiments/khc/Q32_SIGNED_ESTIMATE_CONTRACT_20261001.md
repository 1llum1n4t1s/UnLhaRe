# signed範囲の商推定・独立数値候補

目的: inline候補の生成コードに残るu64変換を、分子nがsigned64へ正確に入る場合だけsigned castへ変える。圧縮性能の保証はなく、branch追加による悪化も検証対象。総合7-Zip超過の目標・固定gateは維持する。

## 実装前に列挙する失敗

- n>i64::MAXをsignedへ直接変換して負値化する。
- i64::MAX近辺のf64丸めが2^63へ達し、整数castの飽和を無視する。
- quotientがi64範囲外の場合にcast結果を正解と扱う。
- guess変更でflagsの頻度が変わることとquotient不一致を混同する。
- checked乗算/ゼロ分母/整数certificate/native fallback/shift経路を変更する。
- 旧異常系・全u64境界・opt2/3・反復・oracleを省く。
- 静的命令削減だけで速度採用する。

## 数値仕様と候補の変更

旧inline exact_div.rs SHA1A82EDBCA1616C3F52F0855ADC449BA1468E4E5F3E1C2031EF254F43B4659BF1を基点に、guess式だけを次へ置換する。

```rust
let mut guess = if n <= i64::MAX as u64 {
    (((n as i64) as f64) / (d as f64)) as i64 as u64
} else {
    ((n as f64) / (d as f64)) as u64
};
```

前段のd==0拒否・checked a*b・d==Q shift・d>Q native商、後段のchecked補正と残余証明は不変。推定値を返す条件は必ずchecked product<=nかつn-product<d。成立しなければ元n/dを返す。従って浮動小数点の誤差幅や一回補正の成功を正確性の必要条件にしない。flagsは実際の補正に従う診断であり、旧flagsと全byte一致は要求しない。quotientとerrorは旧と同じ。

signed枝ではnのinteger castが正確、d>=1、f64商は非負かつfinite。上側丸めで2^63へ達する場合もRustのas i64は上限へ飽和し、負値/未定義にはならない。そのguessをu64へ変換しても非負。証明に失敗した推定はfallbackされる。n>MAXは旧式を保持する。KT分子はzero<=562036803から2^62未満、alpha分子はQだが、posterior分子はsigned64上限を超え得るため無条件signed化しない。

一次仕様: [Rust Reference numeric casts](https://doc.rust-lang.org/reference/expressions/operator-expr.html#numeric-cast)。整数→floatはnearest ties-to-even、float→integerはゼロ方向丸めと範囲外飽和。上の安全性は境界検査とinteger certificateによる局所推論であり、4OSの性能/同一float実装保証ではない。

## 独立数値E2E

担当一人は新 `signed-estimate-quotient/{exact_div.rs,audit_cli.rs,verify.ps1}` のみを所有。旧audit CLIと独立BigInteger oracleを再利用し、元30937recordsを包含した上でi64::MAX±4096近傍、2^53近傍、KT cap、d=1/2/3/Q±1、積が境界を跨ぐ二因子、全u64上限を追加し65536records以内に保持する。seed固定、opt2/3・各2反復・quotient全件oracle一致/certificate/flags分類を実際CLIで確認、旧29checks/31invocations以上の正常異常系を保持する。入力/output/source/compiler/contractのreadlock前後SHAを記録し、owned tmp残存0を確認する。

Rust1.98.1、edition2024、panicabort、opt2/3、root `build/khc-signed-estimate-quotient-20261001/`。全u64完全列挙やOOM/I/O fault/codec/frame/性能を証明したとしない。新Rustだけskip_children fmt、PowerShell Parser。既存source/proof/製品/x86/Git/version/CPU設定/共有cache/外部書込を変更しない。親は契約/文書、後続codecと性能の工程判断を所有し、今回は数値証拠が成立する前にcodecへ入れない。
