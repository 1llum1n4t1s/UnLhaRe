# 検証記録 — 2026-09-17

## 1.0.1 アプリ連携API

- Windows x64: fmt、clippy `-D warnings`、Rust 26試験、Releaseビルド成功。選択展開、キャンセル、既存出力保持、JSON ABI、新しいno-replace rename経路の強制実行を含む。
- Windows ARM64: Releaseクロスビルド成功。macOS x64/ARM64: 全ターゲットのcargo check成功。ネイティブ実行はModern Rust CIで確認する。
- .NET 10: C#経由のUnicode往復、選択、上限、取消、コールバック例外、最終通知内取消を確認。x64 Native AOT実行成功、ARM64 Native AOTクロスビルド成功。
- NuGet実物: PackageReference経由のx64 Native AOT実行、CPU別DLLとライセンスのpublish同梱を確認。
- 4環境のネイティブCI、署名・公開物のハッシュとNuGet公開確認はリリースごとの `artifacts/release-<version>/release-state.json` に記録する。

以下は1.0.0実装時のローカル検証記録。1.0.0の4環境ネイティブCIは [run 35207328000](https://github.com/1llum1n4t1s/UnLhaRe/actions/runs/35207328000) で成功済み。

## ローカル確認

環境: Windows x64、Visual Studio 2026 / MSVC v145、Rust 1.98.1。

| 対象 | 結果 |
| --- | --- |
| fmt / clippy `-D warnings` | 成功 |
| Rustテスト | 16件成功（CRC既知値1、writer6、公開API往復等5、C ABI3、CLI1） |
| Windows x64 | Release DLL/CLI生成、C17 consumerのリンク・DLLロード・ABI 1/JSON一覧を確認 |
| Windows ARM64 | Release DLL/CLI生成、C17 consumerのリンク、PE machine=AA64を確認。実行は未確認 |
| macOS ARM64 / x64 | 両ターゲットの `cargo check --locked --all-targets` 成功。ネイティブリンク・実行は未確認 |
| 既存正常fixture | lha-test16-l1/l2/lg、lha-test20-sjis/utf8の5書庫を新CLIで検査成功 |

fixtureは `../UnLha32Re/sample/lha-master/tests/` のローカル比較資料で、内容は空ファイルのヘッダー／名前検証です。本文の圧縮・復号はwriterのLH0/LH5/LH6/LH7生成物を別のdecoderで読み戻すテスト、および公開APIの日本語・絵文字・空項目の往復で確認しました。旧UNLHA32.DLLとの全機能・全方式の一致を確認した結果ではありません。

## 再確認の入口

- Windows: `pwsh -NoProfile -File scripts/build.ps1 -Test`
- macOS: `bash scripts/build.sh --test`
- CI: `../.github/workflows/modern.yml` で4環境のnativeテストとC consumerを実行。Windowsでは.NET Native AOT consumerも実行。

ローカルbundleは署名前の開発成果物です。配布は4環境のnative CIとWindows署名確認を経た別工程です。macOSはad-hoc署名であり、Developer ID署名・公証には対応していません。
