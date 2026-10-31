# KHC1BLK有限比較

2026-10-05。対象はWindows x64、1MiB以下の独立ブロック。アーカイブ/solidの比較ではない。
KHC1のpaid-history、低履歴のみのablation、旧KHC0LAB Standard、Zstd1.5.7 -3、
7-Zip26.03のXZ/LZMA2 -mx9を実往復する。frame header・モデル・辞書packetを全サイズに含める。
共有する事前学習モデル・外部復号サービスはない。新形式は製品Rust APIを使い、旧方式だけ研究API。

## 再現

`UnLhaRe/` でRust1.98.1・Cargo.lock・共有build/cargoを使う。
現在のrunnerは版固定toolchain/tool/corpusをpinするため、別版を同条件の測定に混ぜない。
必要な既存データ・tool配置、SHA、取得元は `../CORPUS_MANIFEST.json`、
`../COMPARISON_PREPARATION_20261005.md`、reportのpinsを参照。
rawコーパス全体をコピーせず、先頭窓だけRAMで使用する。

```powershell
$env:RUSTC='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$cargo='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/cargo.exe'
& $cargo build --locked --offline --release --target x86_64-pc-windows-msvc --example khc_block_io --example khc_current_io
$helper=(Resolve-Path 'build/cargo/x86_64-pc-windows-msvc/release/examples/khc_block_io.exe').Path
$current=(Resolve-Path 'build/cargo/x86_64-pc-windows-msvc/release/examples/khc_current_io.exe').Path
$arguments=@{
    HelperExe=$helper; HelperSha256=(Get-FileHash $helper).Hash
    CurrentHelperExe=$current; CurrentHelperSha256=(Get-FileHash $current).Hash
    Attempt='final1'; ReplayLabel='replicate-1'
}
# build終了後、他のcompile/native診断を併走させない。
& ./experiments/khc/product-comparison/run.ps1 @arguments -PreflightOnly
& ./experiments/khc/product-comparison/run.ps1 @arguments
& ./experiments/khc/product-comparison/verify.ps1 -ReportPath 'build/khc-product-comparison-20261005-final1-replicate-1/report.json'
```

runnerはPS7以上、verifierはDateKind StringのためPS7.5以上。記録環境は7.6.5。
既存出力は拒否する。別再現には未使用の短いReplayLabelを指定し、結果を上書きしない。
再現の自動繰返しや無制限探索は行わない。実行前にFAILURE_PLAN.mdとCURRENT_BASELINE_PLAN.mdを確認する。

## 評価範囲と注意

- matched/ablationはsingle-worker、WS/private64MiB、child60秒。率優先LZMA2_8mだけ160MiB。
- 暖機1+測定9、各roundで順序反転、CPU15%以下確認。13fixtureのSHA/window/役割を保存。
- 時間はprocess起動+binary IO+10ms polling。小入力の純codec速度・微秒単位の順位は分からない。
- memoryはprocess kernel peak/ポーリング値。短命processの最終peakは取り逃がし得る。
- KHC0 Standardは辞書1MiB/Range。現LHA public APIはfilesystem専用なので同RAM scopeで測っていない。
- Zstd19は予算内事前memory推定なし、LZMA2_64mは事前予算外で未実行。最強設定全般への優位は主張しない。
- Canterbury2件はdevelopment、Silesia4件の先頭256KiBはholdout_window。全文・solid・全分野代表性はない。
- 空/極小、seeded乱数、公開test keyでの実AES-CBC、実Zstd frameも測り、不縮小時のstored切替を確認する。
- report256KiB/専用出力8MiB、free5GiB、suite30分。raw/frame disk0。失敗・中断・未実行を成功と混同しない。

元initial/repair1は基盤不具合、repair2はbuild重複のため校正用。最終速度評価はfinal1だけを用いる。
検証器はreportの契約・現存identity・コーパス窓を照合するが、それ自体は再復号せず、
runnerの実byte一致判定を根拠としている。外部ツールの配布ライセンスは準備文書に区別する。
