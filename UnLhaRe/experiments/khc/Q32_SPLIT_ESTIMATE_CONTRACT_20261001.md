# signed/wide商推定分離の先行契約

目的: signed推定候補は数値正確性を示したが、コンパイラが両castを計算後選択するため狙った変換省略を支持しなかった。wide unsignedのguessだけを非inline関数へ分離し、small branchで不要なwide計算が実行されない生成コードを評価する。

## 実装前の失敗条件

- helper分離でも両変換が残る、または毎回wideを呼ぶ。
- wide呼出cost、branch misprediction、コード増大で総合時間が悪化する。
- wideは低頻度だと仮定してcold属性やbranch条件を変更する。
- guess以外の補正/certificate/fallback/error/flagsを変える。
- 前候補全56191records、旧異常系、opt2/3・反復・readlocksを省く。
- 静的命令差を速度向上や総合7-Zip超過へ読み替える。

## 数値候補

新 `split-estimate-quotient/{exact_div.rs,audit_cli.rs,verify.ps1}` を担当一人が所有。基点はsigned helper SHA `4DB94AD93B403BCB41F85973A16CAA60A9A504DCD05B2FF9DA7F6224B2144106`。変更は末尾へ次を追加し、n>signedMAX側のguess式をこの呼出へ置換するだけ。

```rust
#[inline(never)]
fn estimate_unsigned(n: u64, d: u64) -> u64 {
    ((n as f64) / (d as f64)) as u64
}
```

small側、境界条件、ratioのinline(always)、flags・全補正・checked整数certificate・native fallback・errorは不変。guess同値なので前候補とquotientだけでなく全diagnostic flags bytes一致も要求。cold/unsafe/target CPU/数値仕様変更を足さない。

前候補verifyを再利用し、56191全recordsのinput/oracleを同bytesで再現・照合する。前候補proof SHA `C3A57EA84F68E93F766AAC7C8BED6F8804FDF7324662BB77F7479FA0E211249C` と全source/EXE/input/outputをreadlock固定して、opt2/3各2repeatで全商/残余/certificate/flags分類をBigInteger oracleと照合、前候補全4rawoutputとfullbyte一致。旧30checks/31CLI以上の異常系を保持。入力集合を拡張/縮小する必要はない。

Rust1.98.1/edition2024/panicabort/opt2/3、専用新root `build/khc-split-estimate-quotient-20261001/`。新Rustskip_children fmt/Parser、beforeafter pins、owned tmp0、独立監査を保持。親は契約/生成診断/後続codec/性能/文書を所有し、実装担当は数値E2E凍結まで。

## 生成コード・次段階

凍結opt3を同LLVM objdumpで再コンパイルせず確認する。small枝でsigned input/guess変換だけ、wideは分岐先の非inline呼出のみとなるか、番地と命令列を証拠にする。PDB名前未確認や静的/動的の境界を示す。数値と生成コードが支持されたら新codecで全frame一致を確認し、inline対照/固定native7zipと同sessionの元性能gateを実測する。

全u64完全列挙/4native/OOM/IOfault/codec/frame/性能は数値E2Eだけで完了としない。既存source/proof/製品/x86/Git/version/CPU設定/共有cache/外部サービスは不変。goalとarchive<=483599B/strict encode<574.5624ms、quiet15%/warm1+9/circular/nativeoptsを維持する。
