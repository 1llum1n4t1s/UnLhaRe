# UnLhaRe — 64bit版

Windows・macOSのx64/ARM64向けLHAライブラリとCLIです。Rust 1.98.1 / edition 2024で実装し、Rust APIとUTF-8のC ABIを提供します。従来の `UNLHA32RE.DLL` を置き換えるABIではありません。既存32bitアプリは `../UnLha32Re/` の互換版を使用してください。

## バージョン1.0.0の配布

[GitHub Releases](https://github.com/1llum1n4t1s/UnLhaRe/releases/tag/unlhare-v1.0.0)で、Windows x64/ARM64はZIP、macOS Intel/Apple Siliconはtar.gzを配布します。`SHA256SUMS.txt` で整合性を確認できます。Windows版のDLL・CLIはAuthenticode署名付きです。macOS版はad-hoc署名で、Developer ID署名・Apple公証はありません。

旧互換版の `v1.0.0` とは別の `unlhare-v1.0.0` タグです。ソースとビルド手順も同じタグから取得できます。[変更履歴](CHANGELOG.md)と[リリース手順](RELEASING.md)を参照してください。

## 機能と制限

| 操作 | 対応 |
| --- | --- |
| 一覧 | 項目名、方式、元サイズ、圧縮サイズ、CRC、ヘッダーレベルをJSONまたはTSVで取得 |
| 検査・展開 | LH0/LH1/LH4/LH5/LH6/LH7/LHX、LZS/LZ5、PM0/PM1/PM2。本文サイズとCRCを確認 |
| 作成 | LH0、LH5（既定）、LH6、LH7。圧縮で大きくなる場合はLH0。レベル2ヘッダー |
| 名前 | 新規作成はUTF-8とUnicode拡張。読取はUnicode拡張優先、コードページ65001/932/51932/20932/1252 |
| プラットフォーム | Windows x64/ARM64、macOS Intel/Apple Silicon。32bitはコンパイル時に拒否 |

コードページ指定のない名前は有効なUTF-8を優先し、それ以外はCP932として読みます。無指定のEUC-JP等を自動判別する機能はありません。LH2/LH3、SFX、書庫の更新・結合・注釈編集、旧DLLコールバック、GUIは現APIの対象外です。展開時の日時・権限・拡張属性の復元は行いません。シンボリックリンクと特殊ファイルは受け付けません。

各APIは独立した状態で動作します。カレントディレクトリ、レジストリ、プロセスのシグナル設定を変更しません。

## CLI

```text
unlhare-cli create output.lzh --source input-directory --method lh5
unlhare-cli list output.lzh --json
unlhare-cli test output.lzh
unlhare-cli extract output.lzh --output extracted
```

作成先の親ディレクトリはあらかじめ作成してください。作成先書庫や展開先ファイルが既に存在する場合はエラーになり、既存内容を保持します。一覧取得だけでは本文の完全性は検査しません。

既定の上限は100,000項目、1ファイル256MiB、合計2GiBです。CLIの `--max-entries` / `--max-entry-bytes` / `--max-total-bytes`、Rustの `Limits` で変更できます。サイズは64bitですが、圧縮は1ファイル分をメモリに保持するため、上限を上げる際は利用可能メモリに合わせてください。C ABIは既定上限を使用します。

展開は出力ディレクトリを基点とするファイル操作を使用し、一時ファイルへの展開とCRC検査後にhard linkでファイルを確定します。同一ファイルシステムのhard linkに対応するNTFS/APFS等が必要です。書庫全体のトランザクションではなく、途中で失敗した場合も先に完了したファイルとディレクトリは残ります。

## ビルド

Rustupを導入し、WindowsではVisual StudioのC++ build toolsと対象アーキテクチャのMSVC/SDK、macOSではXcode Command Line Toolsを用意します。toolchainは `rust-toolchain.toml`、依存版は `Cargo.lock` で固定します。

```powershell
# このディレクトリで実行
pwsh -NoProfile -File scripts/build.ps1 -Test
rustup target add aarch64-pc-windows-msvc
pwsh -NoProfile -File scripts/build.ps1 -Target aarch64-pc-windows-msvc
```

```sh
# macOSのネイティブ環境
bash scripts/build.sh --test
```

bundleは `artifacts/<target>/` に作成します。Windowsは `unlhare.dll`、`unlhare.dll.lib`、`unlhare-cli.exe`、macOSは `libunlhare.dylib`、`unlhare-cli` を含みます。ヘッダー、ライセンス、Cargo.lockも同梱します。署名・公証・公開は別工程です。

WindowsからmacOSターゲットを指定した場合は `cargo check` のみ実行し、配布物を作りません。クロスビルド成功だけでは実行確認済みとは扱いません。CIは4環境でネイティブビルド・テストを行います。今回の確認済み範囲と未実行範囲は [検証記録](VALIDATION.md) に記載しています。

## ライブラリ

Rustでは `create_from_directory` / `create_archive` / `list_archive` / `verify_archive` / `extract_archive` を使用します。`cargo doc --no-deps` でAPIリファレンスを生成できます。

C/C++では `include/unlhare.h` と同じアーキテクチャのライブラリを使用してください。ABIバージョンは1です。全パスはNUL終端UTF-8、サイズはuint64_t、出力バッファは呼び出し元で確保・解放します。NULLと容量0で必要バイト数（終端NULを含む）を照会し、確保して再呼び出しします。入力・出力・サイズポインターは有効かつ重ならない領域にしてください。最終エラーはスレッド別に保持し、成功では消去しません。

`examples/c_api.c` はABI確認とJSON一覧を行う例です。Windowsでは `cl /utf-8 /Iinclude examples/c_api.c unlhare.dll.lib`、macOSでは `cc -Iinclude examples/c_api.c -L. -lunlhare -Wl,-rpath,@executable_path` のようにリンクし、実行時にライブラリをロード可能な場所へ配置します。

自前コードはリポジトリのMITライセンスです。依存関係の告知は `THIRD_PARTY_NOTICES.md`、ライセンス原文は `THIRD_PARTY_LICENSES.txt` を参照してください。
