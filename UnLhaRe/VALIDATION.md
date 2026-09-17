# 検証記録 — 2026-09-18

## Unreleased API level 3 利用性改善

- Lhamiel側の利用箇所を照合し、一覧の途中キャンセル、更新日時取得・通常ファイルの任意の時刻復元、入力I/O失敗だけをスキップする結果通知版圧縮、Windows相対パス区切りの受理を追加した。従来のC関数・.NETメソッドのシグネチャは維持。
- Windows x64で `scripts/build.ps1 -Target x86_64-pc-windows-msvc -Test` が成功。fmt、clippy、Rust全48試験、Releaseとローカルbundleを確認。API level 3のC17 consumerを `/W4 /WX` でリンクし、新旧一覧APIを実行した。
- .NET 10の通常実行とwin-x64 NativeAOT publish・実行が成功。一覧の初期/途中キャンセル、トークンと例外の伝播、日時、読取段階の入力失敗と項目順、既存出力保持を実native DLLとの契約試験で確認した。実行環境はWindows x64 / .NET SDK 10.0.401。実行シェルにOS環境変数がないためNativeAOTの初回判定が失敗し、実OSを確認してMSBuildへ `-p:OS=Windows_NT` を明示した再実行で成功。
- Windows ARM64・macOS x64/ARM64は全ターゲットのcargo checkに成功。macOSでnofollow拒否が入力I/Oスキップへ分類されないよう追加修正し、関連18試験とmacOS ARM64全ターゲットclippy `-D warnings` も成功。macOS/ARM64ネイティブ実行と、旧DOS日時の夏時間境界は未実測。
- 一覧の日時は無効・曖昧ならnull。ディレクトリ時刻復元とストリーミング圧縮は未実装。公開NuGet 1.0.1への反映・Lhamielの参照更新はこのローカル検証に含めない。
- C実行確認用の `build/api3-c-consumer/` は自動承認レビューに削除を拒否されたため保持。再現用のC実行ファイル、オブジェクト、通常テキスト入力とLHA書庫のみを含む。確認済みのため削除可能になった時点で清掃する。

## Unreleased 圧縮性能改善

- AMD Ryzen 5 7640HSのWindows x64 ReleaseでCRC-16/ARC単体を計測し、8MiBを9回処理したビット単位実装501.5MiB/sに対し、`crc-fast` 1.10.0は29,217.2MiB/sだった。実行時に `x86_64-avx512-vpclmulqdq` が選択され、既知値 `123456789 = 0xBB3D`、分割更新、8MiB入力の結果が一致した。
- 同じ8MiBの反復データと疑似乱数データを各方式で書庫化し、変更前3回と変更後15回の中央値を比較。Storedは65.4msから32.2ms（約50.8%短縮）、LH5は187.4msから151.0ms（約19.4%短縮）、LH7は114.2msから80.9ms（約29.2%短縮）となった。
- Stored・LH5・LH7の書庫は変更前とバイト単位で一致し、SHA-256は順に `C62DE41866D62E22D8195B07B7D913B8600A16BC1ECE1A7B5FB2AC383DA3CE2`、`DD4B921A1E616A07FC3A1DC5BE41E323766DA0ACB9783EEF254C0ACA72AEFBDE`、`025AD4B0489E538ACD8195B07B7D913B8600A16BC1ECE1A7B5FB2AC383DA3CE2`。全書庫の展開長とCRC検査も成功した。
- CPU命令の実行時選択を同梱した結果、Windows x64 ReleaseのDLLは904,704 bytesから1,650,688 bytes、CLIは1,254,912 bytesから2,002,944 bytesへ増加した。
- Windows x64のfmt、clippy `-D warnings`、Rust全48試験、Release bundle、Windows ARM64 Releaseビルド、macOS x64/ARM64のrelease checkに成功。`cargo-audit` 0.22.2でRustSec 1,247件のadvisoryとCargo.lockの133依存を照合し、既知の脆弱性は検出されなかった。
- Windows x64 Releaseで、8MiBの反復データと固定seed 20260917の8MiB疑似乱数データをLH5書庫へ作成。変更前3回の中央値340.2msに対し、変更後15回の中央値320.3ms（約5.8%短縮）。生成物は8,411,330 bytes、SHA-256 `99D50CEC35DE99A04EF9698FA5FA2463F0D57459157EA52AC02D5F2360983E0F`で変更前と一致した。
- CRCの別走査とLH0フォールバック時の本文複製を除去し、LZSS作業領域・圧縮バッファを1項目ごとの生成から1書庫ごとの再利用へ変更した。固定seed入力でLH5/LH6/LH7からLH0へ戻る経路と、圧縮後のキャンセルで書庫を公開しない経路を回帰試験に追加した。
- 比較案も同じ環境で計測し、CRCテーブルは64MiBを5回処理してビット単位610.6msに対し627.7ms、delharc `fast-tree-build`は100回検査で既定3867.9msに対し3922.1msだったため不採用。64KiB `BufReader`は3848.4msで差が測定揺れの範囲だったため既定値を維持した。

## Unreleased セキュリティ修正

- 圧縮元ファイルを同サイズの別ファイルへ差し替える回帰試験、圧縮元・展開先の基点と中間要素でシンボリックリンクを追跡しない試験、書庫ファイル上限の試験を追加。
- Windows予約デバイス名の全形式を作成前に拒否し、細工した書庫内名も一覧・検査・展開で拒否する回帰試験を追加。MS-DOSのシンボリックリンク属性を付けた書庫も同じ3経路で拒否することを確認した。
- Windows x64でfmt、全53試験、clippy `-D warnings`、Releaseビルド、`git diff --check`に成功。
- Windows x64でfmt、clippy `-D warnings`、Rust全34試験、Releaseビルド、RustSecのCargo.lock監査、NuGetの推移依存を含む脆弱性監査に成功。既知の脆弱性は検出されなかった。
- macOS x64/ARM64は全ターゲットのcargo checkに成功。ネイティブ実行はCIで確認する。

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
