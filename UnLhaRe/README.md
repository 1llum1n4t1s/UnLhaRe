# UnLhaRe — 64bit版

Windows・macOSのx64/ARM64向けLHAライブラリとCLIです。Rust 1.98.1 / edition 2024で実装し、Rust APIとUTF-8のC ABIを提供します。従来の `UNLHA32RE.DLL` を置き換えるABIではありません。既存32bitアプリは `../UnLha32Re/` の互換版を使用してください。

## バージョン1.0.3の配布

[GitHub Releases](https://github.com/1llum1n4t1s/UnLhaRe/releases/tag/unlhare-v1.0.3)で、Windows x64/ARM64はZIP、macOS Intel/Apple Siliconはtar.gzを配布します。`SHA256SUMS.txt` で整合性を確認できます。Windows版のDLL・CLIはAuthenticode署名付きです。macOS版はad-hoc署名で、Developer ID署名・Apple公証はありません。

旧互換版の `v1.0.0` とは別の `unlhare-v1.0.3` タグです。ソースとビルド手順も同じタグから取得できます。[変更履歴](CHANGELOG.md)と[リリース手順](RELEASING.md)を参照してください。

## 機能と制限

| 操作 | 対応 |
| --- | --- |
| 一覧 | 項目名、方式、元サイズ、圧縮サイズ、CRC、ヘッダーレベルをJSON、TSV、または項目単位コールバックで取得 |
| 検査・展開 | LH0/LH1/LH4/LH5/LH6/LH7/LHX、LZS/LZ5、PM0/PM1/PM2。本文サイズとCRCを確認 |
| 作成 | LH0、LH5（既定）、LH6、LH7。圧縮で大きくなる場合はLH0。レベル2ヘッダー |
| 名前 | 新規作成はUTF-8とUnicode拡張。読取はUnicode拡張優先、コードページ65001/932/51932/20932/1252 |
| プラットフォーム | Windows x64/ARM64、macOS Intel/Apple Silicon。32bitはコンパイル時に拒否 |

コードページ指定のない名前は有効なUTF-8を優先し、それ以外はCP932として読みます。無指定のEUC-JP等を自動判別する機能はありません。LH2/LH3、SFX、書庫の更新・結合・注釈編集、旧DLLコールバック、GUIは現APIの対象外です。従来の展開APIは日時を復元しません。API level 3では通常ファイルの更新日時を任意で復元できます。権限・拡張属性は復元せず、シンボリックリンクと特殊ファイルは受け付けません。

各APIは独立した状態で動作します。カレントディレクトリ、レジストリ、プロセスのシグナル設定を変更しません。

## API level 3

バージョン1.0.2で追加したAPIです。ABI 1と既存関数のシグネチャは維持します。

- `list_archive_with_progress` / `unlhare_list_json_with_progress` は一覧走査中の進捗・キャンセルに対応し、C版は1回の走査結果を同期JSONコールバックで返します。
- 一覧の `modified_unix_seconds` は更新日時のUnix秒です。日時不正・変換不能ならnull。タイムゾーンのない旧DOS日時は実行環境のローカル時間として解釈し、夏時間の切替などで一意に決まらない場合もnullとします。
- `extract_archive_with_options` の `preserve_timestamps`、JSON extract要求の同名フィールドで、通常ファイルの更新日時をCRC検証後・公開前に復元できます。既定はfalse、ディレクトリ日時は変更しません。
- `create_archive_with_report` / `unlhare_create_json_report` は読み取れない入力だけをスキップし、入力順の `written` / `skipped` とエラー理由を返します。スキップするのは入力側I/Oエラーだけです。容量上限、安全性違反、出力I/Oエラー、キャンセルは書庫全体を失敗させます。API level 3の既定動作では、全入力をスキップした場合も空の書庫を作成します。従来の作成APIは1件の失敗でも全体を中止します。
- 圧縮元一覧の書庫内名は `\\` と `/` の両方を受け付け、`/` に正規化してから検証します。絶対パス・親参照・正規化後の重複は引き続き拒否します。

Cの結果JSONは通知中だけ有効で、長さはNULを含まないバイト数です。結果通知からは中断できません。圧縮結果を通知する時点で書庫は確定しています。.NETからの使い方は [バインディングの追加API](bindings/dotnet/README.md#api-level-3) を参照してください。

## API level 4

バージョン1.0.3で追加したAPIです。ABI 1と既存関数のシグネチャを維持します。

- `unlhare_last_error_kind()` は呼び出しスレッドの直前エラーを、I/O、書庫形式、非対応機能、上限、無効パス、既存出力、無効引数、キャンセル、バッファ不足、内部エラーへ分類します。メッセージと同様に成功では消去しません。
- `unlhare_create_json_report` のcreate要求へ `"fail_if_all_skipped":true` を指定すると、1件も書き込めなかった場合は一時書庫だけを破棄して失敗します。省略時はAPI level 3と同じく有効な空書庫と項目別結果を返します。
- WindowsとmacOSでは圧縮元、展開先、書庫出力先の親をファイルシステムルートのハンドルから1要素ずつ開き、途中のjunction、シンボリックリンク、その他のreparse pointを追跡しません。macOS標準の `/var`、`/tmp`、`/etc` は、ルート直下のリンク先がOS既定の `/private/...` と一致する場合だけ物理パスへ正規化します。展開先の欠けた要素も1件ずつ作成して非追跡で再検査します。

.NETの通常の `ArchiveClient.List(path)` はAPI level 3以上のnativeで自動的に1回走査を使用し、level 2だけ従来のサイズ照会方式へ戻ります。`ArchiveNativeException.Kind` はAPI level 4未満では `Unknown` です。作成結果の状態は `ArchiveCreateEntryStatus` enumで返し、`ArchiveCreateReportOptions(FailIfAllSkipped: true)` で空書庫の公開を拒否できます。

## API level 5

次回配布向けの現在のソースで追加したAPIです。ABI 1と既存関数のシグネチャを維持します。

- Rustの `visit_archive_entries` / `visit_archive_entries_with_progress` は、所有権を渡した `Entry` を書庫順に同期通知します。visitorが `false` を返すとキャンセルします。
- Cの `unlhare_list_entries_json` は1項目を1個のJSON objectとして同期通知し、項目コールバックの非0戻り値でキャンセルします。全件配列は作りません。
- .NETの `ArchiveClient.VisitEntries` は `Action<ArchiveEntry>` を呼出し元スレッドで実行します。API level 5のnativeを必要とし、`CancellationToken`、`ArchiveLimits`、進捗通知を受け付けます。通常の `List` もlevel 5では同じnative経路からmanagedの結果だけを収集します。

この経路は全件の `Entry` と集約JSONをnativeメモリへ保持しないため、巨大書庫のピークメモリと最初の項目を受け取るまでの待ち時間を抑えます。全件を処理する場合は全ヘッダーの走査時間そのものは必要です。また、名前重複と上限を検査するための管理情報は走査終了まで保持します。後続ヘッダーの異常やキャンセルより前に通知済みの項目は取り消されないため、呼び出し側は完了戻り値を確認してから一覧全体を確定してください。

## CLI

```text
unlhare-cli create output.lzh --source input-directory --method lh5
unlhare-cli list output.lzh --json
unlhare-cli test output.lzh
unlhare-cli extract output.lzh --output extracted
```

作成先の親ディレクトリはあらかじめ作成してください。作成先書庫や展開先ファイルが既に存在する場合はエラーになり、既存内容を保持します。一覧取得だけでは本文の完全性は検査しません。

既定の上限は100,000項目、1ファイル256MiB、展開後合計2GiBです。CLIの `--max-entries` / `--max-entry-bytes` / `--max-total-bytes`、Rustの `Limits`、C API level 2のJSON指定で変更できます。読取可能な書庫ファイルは展開後合計上限に64MiBを加えたサイズまで、項目名などの保持に使うメタデータは合計64MiBまでです。サイズは64bitですが、圧縮は1ファイル分をメモリに保持するため、上限を上げる際は利用可能メモリに合わせてください。従来のC関数は既定上限を使用します。

ディレクトリ一括圧縮と展開は、シンボリックリンクを追跡せずに開いた基点ディレクトリのハンドル配下だけを操作します。WindowsとmacOSのどちらも基点までの全要素と、操作中にたどる各ディレクトリのリンクを拒否します。Windowsではjunctionを含むすべてのreparse pointが対象です。macOSではOS標準の `/var`、`/tmp`、`/etc` だけを既定の `/private/...` と一致するときに正規化し、利用者が作成した中間symlinkは拒否します。書庫作成は検査済み出力親ハンドル内の一時ファイルへ書き込み、展開は一時ファイルへの展開とCRC検査後にhard linkでファイルを確定します。hard linkが利用できなければOSの既存ファイルを置換しない原子的なrenameを使用します。どちらの公開も検査済み親ハンドルを基点にし、確定前の失敗・キャンセルでは一時ファイルだけを削除します。書庫全体のトランザクションではなく、途中で失敗した場合も先に完了したファイルとディレクトリは残ります。

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

追加したAPI level 2と.NET APIは、Lhamielに限らず他のアプリでも利用できる汎用APIです。利用アプリやUIフレームワークへの依存はなく、入力パス、選択項目、容量上限、進捗通知とキャンセルを呼び出し元が指定します。UIへの通知の転送・間引き、設定保存、上書き確認、ファイル関連付け、アプリの更新処理は呼び出し側で実装してください。

Rustでは `create_from_directory` / `create_archive` / `list_archive` / `visit_archive_entries` / `verify_archive` / `extract_archive` を使用します。`cargo doc --no-deps` でAPIリファレンスを生成できます。

作成・検査・展開の `*_with_progress` APIは同期コールバックを受け付け、`false`でキャンセルします。LH5/LH6/LH7の単一ファイルの圧縮計算中はキャンセルを受け付けず、計算の前後に確認します。選択展開の名前は完全一致で、未選択項目もヘッダーと上限の検査対象です。

Windowsの.NET 10アプリではNuGet `Kagayoi.UnLhaRe` を使用できます。x64/ARM64のDLL、Native AOT対応の `ArchiveClient`、依存ライセンスを同梱します。版を固定してlockfileを保存してください。詳細は [C#バインディング](bindings/dotnet/README.md) を参照してください。

C ABI 1を維持したAPI level 2では `unlhare_run_json` と `unlhare_list_json_ex` を追加しています。`unlhare_api_level()`で対応を確認し、同期コールバックは0で続行、非0で中断します。キャンセル時の戻り値は5です。

`unlhare_run_json`の入力例:

```json
{"operation":"create","output":"out.lzh","entries":[{"path":"input.txt","name":"docs/input.txt"}],"method":5}
```

```json
{"operation":"extract","archive":"out.lzh","destination":"out","entries":["docs/input.txt"]}
```

```json
{"operation":"verify","archive":"out.lzh"}
```

一覧用の `unlhare_list_json_ex` と `unlhare_list_entries_json` は `{"archive":"out.lzh"}` を受け付けます。各リクエストへ `"limits":{"max_entries":100000,"max_entry_bytes":268435456,"max_total_bytes":2147483648}` を追加できます。limitsの省略は既定値、指定時は3値すべてが必要です。展開のentries省略またはnullは全項目、空配列は本文を展開しない指定です。ディレクトリ名だけを指定しても子孫は含みません。

C/C++では `include/unlhare.h` と同じアーキテクチャのライブラリを使用してください。ABIバージョンは1です。全パスはNUL終端UTF-8、サイズはuint64_t、出力バッファは呼び出し元で確保・解放します。NULLと容量0で必要バイト数（終端NULを含む）を照会し、確保して再呼び出しします。入力・出力・サイズポインターは有効かつ重ならない領域にしてください。最終エラーのメッセージとAPI level 4の分類はスレッド別に保持し、成功では消去しません。

`examples/c_api.c` はABI確認とJSON一覧を行う例です。Windowsでは `cl /utf-8 /Iinclude examples/c_api.c unlhare.dll.lib`、macOSでは `cc -Iinclude examples/c_api.c -L. -lunlhare -Wl,-rpath,@executable_path` のようにリンクし、実行時にライブラリをロード可能な場所へ配置します。

自前コードはリポジトリのMITライセンスです。依存関係の告知は `THIRD_PARTY_NOTICES.md`、ライセンス原文は `THIRD_PARTY_LICENSES.txt` を参照してください。
