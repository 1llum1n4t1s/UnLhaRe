# UnLhaRe — 64bit版

Windows x64/ARM64とmacOS ARM64向けLHAライブラリとCLIです。Rust 1.98.1 / edition 2024で実装し、Rust APIとUTF-8のC ABIを提供します。従来の `UNLHA32RE.DLL` を置き換えるABIではありません。既存32bitアプリは `../UnLha32Re/` の互換版を使用してください。

## バージョン1.0.4の配布

[GitHub Releases](https://github.com/1llum1n4t1s/UnLhaRe/releases/tag/unlhare-v1.0.4)で、Windows x64/ARM64はZIP、macOS Intel/Apple Siliconはtar.gzを配布済みです。この1.0.4の既発行物は保持しますが、現在のmacOSサポート・ビルド・検証・今後の配布対象はApple Silicon（ARM64）だけです。`SHA256SUMS.txt` で整合性を確認できます。Windows版のDLL・CLIはAuthenticode署名付きです。macOS版はad-hoc署名で、Developer ID署名・Apple公証はありません。

旧互換版の `v1.0.0` とは別の `unlhare-v1.0.4` タグです。ソースとビルド手順も同じタグから取得できます。[変更履歴](CHANGELOG.md)と[リリース手順](RELEASING.md)を参照してください。

## 機能と制限

独自形式KHC1の開発版をRust API `unlhare::khc` とCLI `khc-*`へ統合しています。[形式仕様](KHC_FORMAT.md)の独立magic/revisionを使用し、既存LHA形式・C ABI・.NET APIは変更しません。配布済み1.0.4にはまだ含まれず、7-Zipとの性能目標は未達成です。[調査・方式選定](experiments/khc/RESEARCH_SELECTION_20261005.md)は既存原理と今回の組合せ・実装上の貢献を区別しています。

[実測結果と再現手順](experiments/khc/product-comparison/RESULT_20261005.md)：Windows x64で13種類・780往復の完全一致、全回帰/fmt/clippyを確認しました。今回のブロック合計は旧研究方式より8.2%、Zstd -3より16.5%小さい一方、LZMA2より2.9%大きく、圧縮速度も劣ります。他3環境は型検査のみで、native動作・総合優位は未確認です。

| 操作 | 対応 |
| --- | --- |
| 一覧 | 項目名、方式、元サイズ、圧縮サイズ、CRC、ヘッダーレベルをJSON、TSV、または項目単位コールバックで取得 |
| 検査・展開 | LH0/LH1/LH4/LH5/LH6/LH7/LHX、LZS/LZ5、PM0/PM1/PM2。本文サイズとCRCを確認 |
| 作成 | LH0、LH4、LH5（既定）、LH6、LH7。圧縮で大きくなる場合はLH0。レベル2ヘッダー |
| 名前 | 新規作成はUTF-8とUnicode拡張。読取はUnicode拡張優先、コードページ65001/932/51932/20932/1252 |
| プラットフォーム | Windows x64/ARM64、macOS Apple Silicon（ARM64）。32bitはコンパイル時に拒否 |

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

バージョン1.0.4で追加したAPIです。ABI 1と既存関数のシグネチャを維持します。

- Rustの `visit_archive_entries` / `visit_archive_entries_with_progress` は、所有権を渡した `Entry` を書庫順に同期通知します。visitorが `false` を返すとキャンセルします。
- Cの `unlhare_list_entries_json` は1項目を1個のJSON objectとして同期通知し、項目コールバックの非0戻り値でキャンセルします。全件配列は作りません。
- .NETの `ArchiveClient.VisitEntries` は `Action<ArchiveEntry>` を呼出し元スレッドで実行します。API level 5のnativeを必要とし、`CancellationToken`、`ArchiveLimits`、進捗通知を受け付けます。通常の `List` もlevel 5では同じnative経路からmanagedの結果だけを収集します。

この経路は全件の `Entry` と集約JSONをnativeメモリへ保持しないため、巨大書庫のピークメモリと最初の項目を受け取るまでの待ち時間を抑えます。全件を処理する場合は全ヘッダーの走査時間そのものは必要です。また、名前重複と上限を検査するための管理情報は走査終了まで保持します。後続ヘッダーの異常やキャンセルより前に通知済みの項目は取り消されないため、呼び出し側は完了戻り値を確認してから一覧全体を確定してください。

## CLI

KHCの既定`mdl`は従来のrevision 1を維持します。明示指定の`hybrid-trial`はMDL/LZ3/LZ8の全試行費用を払って最小frameを選び、`binary-adaptive`は文字byte率によってMDL/LZ8を選びます。新戦略はrevision 2で、旧decoderでは展開できません。Rustでは`compress_block_with_strategy` / `CreateOptions.block_strategy`を使用します。選択込みの結果・再現手順は[hybrid評価](experiments/khc/hybrid/RESULT_20261005.md)を参照してください。未見評価・7-Zip総合優位は未確認です。

明示指定の`record-trial`（Rust `BlockStrategy::RecordTrial`）はrevision 3の実験方式です。復元したデータから繰り返しを予測し、旧方式より小さい結果だけを選びます。外部モデル不要、非利益時は旧frame内包またはstoredです。旧decoderはrevision 3を拒否します。[2026-10-07のrevision 3評価](experiments/khc/row-copy-pruned-rans/RESULT_20261007.md)の既知11入力では実書庫457,017Bで、強設定の7-Zip 26.04より約5.1%小さくなりました。一方、展開検証時間は約2倍かかり、速度目標は未達です。これはG32の測定結果ではありません。未見入力・Zstd・総合優位は未確認なので、既定にはしていません。

明示指定の`gather32-trial`（Rust `BlockStrategy::Gather32Trial`）はrevision 4の実験方式です。MDLの逆BWTを32本のchainで復元し、AVX2が使えないCPUでは同じ形式をscalarで復元します。既定`mdl`とrevision 1〜3の読取は維持します。Windows x64で実CLIの作成・一覧・検証・展開を確認しています。2026-10-11のCanterbury調整用11ファイルでは、同じ456,981Bの書庫の復号検証が21組の比較で中央値81.89msから45.46msへ改善しました。ただし7-Zip 26.04（7z/LZMA2、481,490B、復号`-mmt=4`）は42.11msで、速度目標は未達です。未見のSilesia 12ファイル・211,938,580Bも完全一致を確認しましたが、書庫は55,065,757B対7-Zipの49,307,880B、21組の復号中央値も1.287s対1.145sで、総合目標には届いていません。ARM64/macOSのnative動作は未検証です。revision 4対応の開発版で試してください。詳細は[形式仕様](KHC_FORMAT.md#archive-revision-4gather32-frame)を参照してください。

明示指定の`delta16-trial`（Rust `BlockStrategy::Delta16Trial`）はrevision 5の実験方式です。16bitの差分をbyte planeへ分け、未変換より小さい完全frameだけを選びます。外部辞書は不要で、既定`mdl`とrevision 1〜4の読取は維持します。Windows x64の実API/CLIで作成・一覧・検証・展開と、旧5戦略の書庫のバイト一致を確認しました。旧decoderはrevision 5を拒否します。全Silesia書庫は旧KHCより878,010B小さくなりましたが、54,187,747Bで同じ制限の7z 49,307,880Bより約9.90%大きく、全量size条件は不合格でした。新しい未見入力・公平な反復性能評価は未実施で、7-Zip優位は未達です。詳細は[形式仕様](KHC_FORMAT.md#archive-revision-5delta16-frame)を参照してください。

明示指定の`record-fast-trial`（Rust `BlockStrategy::RecordFastTrial`）はrevision 6の実験方式です。幅変更schedule付きcopy frameがBinaryAdaptiveの完全frameより厳密に小さい場合だけKRS2を保存し、それ以外はBinaryAdaptiveへ完全fallbackします。既定`mdl`とrevision 1〜5の読取は維持し、revision 1〜5の旧decoderはrevision 6を拒否します。2026-10-15のCanterbury `ptt5` 単一ファイルscreenではKRS2が3回とも選ばれ、完全書庫46,274Bになりましたが、7-Zip 26.04の42,199Bより9.66%大きく、優位性は未達です。小規模screenのみのため既定化していません。詳細は[形式仕様](KHC_FORMAT.md)と[候補選定・比較結果](experiments/khc/RESEARCH_SELECTION_20261005.md)を参照してください。

進捗なしのRust `verify_archive` / `extract_archive`（CLI `khc-test` / `khc-extract`）は、G32を含む適格なrevision 4/5書庫（revision 5は内側のG32を含むもの）のblock復号を最大4ワーカーで処理します。CRC検査・書き出し・ファイル公開は書庫順です。4,096項目または名前の合計512KiBを超える書庫、適格性の事前走査に失敗した書庫、G32を含まない書庫とrevision 1〜3は逐次処理します。`*_with_progress`はコールバックと読取タイミングを保つため引き続き逐次処理です。既定戦略・公開関数の引数は変えていません。

明示指定の`spatial-bits-trial`（Rust `BlockStrategy::SpatialBitsTrial`）はrevision 7の実験方式です。因果copyに続くliteralのXOR残差を、復元済みの空間contextから整数bit確率で符号化します。完全frameが格納より小さくなる場合だけ圧縮し、それ以外は同じKCS1形式のstoredを使います。既定`mdl`とrevision 1〜6の読取は維持し、旧decoderはrevision 7を拒否します。Windows x64のregistered E2Eでは複数fileのAPI/CLI作成・一覧・検査・展開、byte/SHA復元、破損入力の拒否、既存出力の保護、旧revision 1/6読込、64 MiB decode budgetを確認済みです。製品性能screenはCPU 15%以下の事前条件を満たさず未実施のため、速度・高水位メモリ・汎用データでの圧縮優位は未評価です。仕様と有限E2Eの実行入口は[形式仕様](KHC_FORMAT.md#archive-revision-7空間bit付き因果copy-frame実験候補)を参照してください。

明示指定の`record-adaptive-trial`（Rust `BlockStrategy::RecordAdaptiveTrial`）はrevision 8の実験方式です。幅変更scheduleとclassごとの適応CDFを使い、完全frameが厳密に小さくなるblockだけKRS3を保存し、それ以外はBinaryAdaptiveの完全KHC1 frameへ戻します。既定`mdl`とrevision 1〜7の読取は維持し、旧decoderはrevision 8を拒否します。revision 8の検証・展開は逐次処理です。2026-10-16のWindows x64 Release registered E2E（5MiB/64entry）が成功し、API/CLI作成・一覧・検証・展開、KRS3採用とfallback、byte/SHA一致、破損拒否・既存出力保護、revision 1〜7の読込を確認しました。KRS3性能screenはCPU quiet gate不合格のため未実行で、圧縮率・速度・高水位メモリの優位は未評価です。[形式仕様](KHC_FORMAT.md#archive-revision-8class適応cdf付きschedule-copy-frame実験候補)を参照してください。

明示指定の`spatial-mdl-trial`（Rust `BlockStrategy::SpatialMdlTrial`）はrevision 9の実験候補です。各blockの完全frameを既定MDLとKCS1で比較し、KCS1が厳密に短い場合だけ切り替え、同長ならMDLを選びます。そのため既定MDLと比べて各blockや同条件の書庫が大きくならない一方、二方式の試行時間と一時memoryが増えます。既定`mdl`は変更せず、性能screen・7-Zip比較・未見データでの優位は未評価です。[形式仕様](KHC_FORMAT.md#archive-revision-9kcs1と既定mdlのblock単位完全frame選択実験候補)を参照してください。

明示指定の`portfolio-trial`（Rust `BlockStrategy::PortfolioTrial`）はrevision 10の実験候補です。MDL、KCS1、KRS2、KRS3の完全frameをこの順でblockごとに試し、同じ長さなら先の方式を選びます。圧縮workspaceを抑えるため候補長だけを保持し、勝者を再符号化します。既存方式の組合せであり、新しいcodec原理ではありません。default `mdl`、revision 1〜9の読取を維持します。速度・高水位memory・製品性能優位は未評価です。[形式仕様](KHC_FORMAT.md#archive-revision-10-4方式のblock単位完全frame選択実験候補)を参照してください。

開発版KHCの実操作（既存`create/list/test/extract`は引き続きLHA）：

MDL復号のモデル表は同じCDFを共有して保持メモリを抑えます。[公開経路の評価](experiments/khc/forest-layout/PUBLIC_RESULT_20261006.md)では調整用11入力の観測展開private最大が約9.74MBから5.33MBへ減りました。全処理の最大メモリは圧縮側でほぼ不変で、全モデルが可変な最悪条件の追加領域も必要です。形式・既定戦略は変更しません。小幅な時間短縮は確認していますが、7-Zip総合優位の証拠ではありません。

```powershell
unlhare-cli khc-create output.khc --source input-directory
unlhare-cli khc-create trial.khc --source input-directory --strategy hybrid-trial
unlhare-cli khc-create adaptive.khc --source input-directory --strategy binary-adaptive
unlhare-cli khc-create record.khc --source input-directory --strategy record-trial
unlhare-cli khc-create gather.khc --source input-directory --strategy gather32-trial
unlhare-cli khc-create delta.khc --source input-directory --strategy delta16-trial
unlhare-cli khc-create record-fast.khc --source input-directory --strategy record-fast-trial
unlhare-cli khc-create spatial.khc --source input-directory --strategy spatial-bits-trial
unlhare-cli khc-create record-adaptive.khc --source input-directory --strategy record-adaptive-trial
unlhare-cli khc-create spatial-mdl.khc --source input-directory --strategy spatial-mdl-trial
unlhare-cli khc-create portfolio.khc --source input-directory --strategy portfolio-trial
unlhare-cli khc-list output.khc --json
unlhare-cli khc-test output.khc
unlhare-cli khc-extract output.khc --output restored-directory
```

KHCは1MiB単位の自己完結CPU codecで、不利益なblockはstoredになります。外部モデル・量子機材不要。一覧は復号せず、完全CRC検証には`khc-test`を使用してください。manifest最大4MiB/100,000項目、名前depth128、codec reservation64MiBに加えてsource/output bufferとmanifestのメモリが必要です。Rustには`compress_block`/`decompress_block`、create/list/visit/verify/extractとprogress入口があります。出力は検証済みentry単位のno-clobberで、後続失敗時に先行entryは残ります。同期のみ・block計算中の取消遅延・directory時刻非復元・C/.NET未対応という制限があります。KHC作成先は入力directoryの外へ指定してください。

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

WindowsからmacOSターゲットを指定した場合は `cargo check` のみ実行し、配布物を作りません。クロスビルド成功だけでは実行確認済みとは扱いません。CIは3環境でネイティブビルド・テストを行います。今回の確認済み範囲と未実行範囲は [検証記録](VALIDATION.md) に記載しています。

## ライブラリ

追加したAPI level 2と.NET APIは、Lhamielに限らず他のアプリでも利用できる汎用APIです。利用アプリやUIフレームワークへの依存はなく、入力パス、選択項目、容量上限、進捗通知とキャンセルを呼び出し元が指定します。UIへの通知の転送・間引き、設定保存、上書き確認、ファイル関連付け、アプリの更新処理は呼び出し側で実装してください。

Rustでは `create_from_directory` / `create_archive` / `list_archive` / `visit_archive_entries` / `verify_archive` / `extract_archive` を使用します。`cargo doc --no-deps` でAPIリファレンスを生成できます。

作成・検査・展開の `*_with_progress` APIは同期コールバックを受け付け、`false`でキャンセルします。LH4/LH5/LH6/LH7の単一ファイルの圧縮計算中はキャンセルを受け付けず、計算の前後に確認します。高圧縮では標準候補と高圧縮候補の計算の間にも確認します。選択展開の名前は完全一致で、未選択項目もヘッダーと上限の検査対象です。

未リリースのAPI level 6では、作成方式にLH4を追加し、圧縮の強さを方式と別に指定できます。Rustは`CreateOptions.effort = CompressionEffort::High`、CのJSON作成要求は`"effort":"high"`、CLIは`create --method lh4 --high-compression`、.NETは`Create`／`CreateWithResults`の`CompressionEffort.High`オーバーロードを使用します。既定は`Standard`で従来の速度を維持します。高圧縮は標準候補と2パスの符号コスト最適化候補を比較し、小さい本文を採用するため、同じ方式の標準出力より大きくなりません。LH0は常に無圧縮です。出力方式は変わらず、対応する既存デコーダーで展開できます。

高圧縮は時間と作業メモリを増やします。最適化の作業領域は入力全体に比例し、入力1バイトにつき数十バイト程度の追加領域を必要とし得ます。巨大な入力では呼び出し側で`max_entry_bytes`を制限してください。この上限は元データの大きさであり、プロセスのメモリ使用量の上限ではありません。圧縮率の改善幅は入力依存で、改善しない場合もあります。

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
