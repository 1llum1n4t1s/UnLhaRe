# 64bit版 UnLhaRe の作業規約

- このディレクトリは新APIのRust版。親のx86 ABI、stdcall、Windows専用試験の制約は `../UnLha32Re/` のみへ適用する。
- 対象はWindows/macOSのx64/ARM64。Rust toolchainとCargo.lockを使い、32bit対応を追加しない。
- `scripts/build.ps1 -Test`（Windows）または `bash scripts/build.sh --test`（macOS）でfmt、clippy、テスト、Releaseビルドとローカルbundleを確認する。
- クロスOSのcargo checkはネイティブビルド・実行検証と区別する。4環境のネイティブ検証は `../.github/workflows/modern.yml`。
- 公開C ABIを変える場合は `src/ffi.rs`、`include/unlhare.h`、`tests/ffi.rs`、C exampleを照合する。UTF-8、固定幅整数、呼び出し側所有バッファを維持する。
- JSON連携APIまたは.NET APIを変える場合は `src/operation.rs`、`src/ffi/app.rs`、`include/unlhare.h`、`tests/app_ffi.rs`、`tests/app_usability_ffi.rs`、`tests/create_report.rs`、`tests/reader_metadata.rs`、`tests/operation.rs`、`bindings/dotnet/src/`、同ContractTestsをまとめて照合する。Windowsではネイティブ対象のbundle作成後、`.github/workflows/modern.yml` と同じNative AOT publishと実行試験を行う。
- 既存出力の保持、CRC検査後のファイル公開、Limits、独立呼び出しの状態分離を維持する。圧縮元・展開先の基点ではシンボリックリンクを追跡せず、Windowsではreparse pointを拒否する。
- 公開Rust API・C ABI・.NET APIは汎用ライブラリとして維持し、Lhamielなど特定の利用アプリやUIフレームワークへ依存させない。設定保存、UIへの進捗転送・間引き、上書き確認、関連付け、製品の更新処理は呼び出し側の責務とする。利用アプリの都合による上限値は公開APIの既定値へ混入させず、呼び出しごとの引数で指定する。
- 設計はルートDESIGN.md、機能・制限・操作はこのREADME.mdを更新する。依存変更では第三者告知・ライセンス全文も更新する。
- バージョン、タグ、配布名、署名・公証、公開前後の確認は `RELEASING.md` を正本とし、4環境のネイティブCIを確認する。クロスOSのcargo checkだけで配布可と判断しない。
- 生成物はartifacts/、中間生成物はbuild/。コミット・公開は明示依頼時のみ。

WindowsでJSON連携APIまたは.NET APIを変更した場合は、次を実行する。

```powershell
$rid = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$target = if ($rid -eq 'win-arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
pwsh -NoProfile -File scripts/build.ps1 -Target $target -Test
$project = 'bindings/dotnet/tests/Kagayoi.UnLhaRe.ContractTests/Kagayoi.UnLhaRe.ContractTests.csproj'
$output = "build/dotnet-contract/$rid"
$nativeRoot = Join-Path $PWD 'artifacts'
dotnet publish $project --configuration Release --runtime $rid --self-contained true --output $output -p:PublishAot=true -p:NativeArtifactsRoot="$nativeRoot"
& (Join-Path $output 'Kagayoi.UnLhaRe.ContractTests.exe')
```
