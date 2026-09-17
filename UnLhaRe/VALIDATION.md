# 検証記録 — 2026-09-17

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
- CI: `../.github/workflows/modern.yml` で4環境のnativeテストとC consumerを実行。今回CIは未実行。

Windows ARM64とmacOSの実機検証、macOSの署名・公証、公開配布は残っています。ローカルbundleは未署名の開発成果物です。
