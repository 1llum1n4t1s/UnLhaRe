# Changelog

## Unreleased

## 1.0.5 - 2026-11-18

- 配信の起動を release/unlhare/<版> ブランチのpushから、main のコミットに付けた軽量タグ `unlhare-v1.0.5` のpushへ変更。アプリ・ライブラリの動作に変更なし。
- 配信をGitHub Releaseから Cloudflare R2（`https://unlhare.kagayoi.com`）へ移行。main のコミットに付けた軽量タグ `unlhare-v<版>` のpushで `release-unlhare.yml` が始まり、同じrunでビルド・Sigilune署名・R2配信（`scripts/Publish-R2.ps1`）を行う。版付きファイルは不変で、`latest.json` と `<版>/release.json`（version・commit・ハッシュ）を配信する。NuGet公開workflowの入力もR2へ変更。1.0.3以前のタグ・GitHub Releaseは配信元として使わず、版とコミットの対応は `RELEASING.md` に残した。
- LHCの並列展開で、次のwaveのframeを、受け取ったblockのCRC検査と書込みより前に投入する。waveの全blockを先に受け取って履歴へ足し（複製せず共有する）、CRCと書込みは書庫順にまとめて行う。書庫形式・出力・検査は変わらない。revision 15の展開は、他の負荷がある中での新旧の対比較で中央値が約7〜14%短くなったが、ゲートの手順のbglでは約1.4%だった。
- LHCの`long-range-mix-trial`（revision 15）で、literalが生データ8byteあたり1個を超えるwaveはliteralの混合を使わない。literalが大半の入力（proteins）で展開が7-Zipの6.4倍から約2.5倍（負荷の少ない診断の値。ゲートの手順では7-Zip側の揺れで1.9倍）になり、サイズは0.824倍から0.837倍になる。開発集合6つと未見集合のテキスト系4つの書庫はbyte単位で変わらない。

- LHCに実験候補`long-range-mix-trial`（`BlockStrategy::LongRangeMixTrial`、archive revision 15、LLZ1BLK frame revision 4）を追加。revision 14の構成に距離slotの文脈の長さ8区分を加え、literalの各bitをLZMAの確率と直前1byte文脈の確率のlogistic混合（整数、12bit確率）で符号化する方式を、0.3%以上縮むwaveだけに使う（frameのmethod 1＝混合なし、2＝混合あり）。parseは1回で両方を同時に書く。200MB級のテキスト系5入力で7-Zip LZMA2 d8m fb273の0.880〜0.944倍（linux tarは0.949から0.944）、展開は7-Zipの2.4〜2.7倍、作成は1.2〜1.7倍。作成の見積もりmemoryは1480MiB。revision 12〜14の出力と読取は変更しない。
- LHCに実験候補`long-range-wide-trial`（`BlockStrategy::LongRangeWideTrial`、archive revision 14、LLZ1BLK frame revision 3）を追加。revision 13の符号のまま、modelを初期化するsegmentを4MiBにし、200MB級のテキスト系5入力すべてで7-Zip LZMA2 d8m fb273の0.95倍以下になる。作成は一致置き場に上限を設けて完成済みsegmentを並列にparseし、frameを順に書き出す（約1.4GiB＋entry、2GiB以下）。revision 12/13の出力と読取は変更しない。
- LHCの長距離LZ（revision 12/13/14）の作成を高速化。出力のbyteは変えずに、一致探索の前処理を1 threadにまとめて次の探索単位と重ね、距離価格と連結rep長の計算結果を再利用する。200MB級のdblpで作成が約15%速くなり、7-Zip比は約1.8から約1.6になった。作成時の見積もりmemoryは32MiB増える（revision 12/13は1160MiB、14は1448MiB）。
- LHCに実験候補`long-range-near-trial`（`BlockStrategy::LongRangeNearTrial`、archive revision 13、LLZ1BLK frame revision 2）を追加。直近のrep距離との差が65536以内の距離を、基準の番号・符号・差で書く近傍符号で、revision 12よりlinux tarで1.28%、ソースtarで1.47%、dblpで0.83%小さくなる。revision 12の読取は変更しない。
- LHCに実験候補`long-range-trial`（`BlockStrategy::LongRangeTrial`、archive revision 12）を追加。8MiB以上のfileを、同じfileの過去64MiBまでを参照するLZMA系の長距離LZ（frame `LLZ1BLK`、2blockを1つのwaveとして並列に復号できる）で格納し、小さいfileはrevision 11と同じ候補を使う。一致探索をhash分担の並列BT4にして作成を速くし、worker数で書庫のbyteは変わらない。大きなfileの作成は約1.2GiBのcodec memoryを要し、64MiBの予算の例外として本人が許可した。enwik8で7-Zip LZMA2 d8m fb273の0.942倍。既定`mdl`と既存revisionの読取は変更しない。
- LHCの並列展開・検証で、重いblockを待つ間も他workerが後続blockを復号できるよう、共有job queueと番号順の並べ直しへ変更。blockの重さに偏りがある書庫で展開が速くなる。書庫形式と出力は変わらない。
- 開発中の独自形式KHCをLHC（LHA High Compression、拡張子`.lhc`）へ改名。Rust APIは`unlhare::lhc`、CLIは`lhc-create`/`lhc-list`/`lhc-test`/`lhc-extract`、仕様は`LHC_FORMAT.md`。書庫・frameのmagicも`KHC*`から`LHC*`へ変更したため、改名前に作成した開発版書庫は読めない。LHAの圧縮方式ではなく、既存LHAツールとの互換性はない。
- LHCの作成・展開・検証に`--threads`（`CreateOptions::threads` / `ExtractOptions::threads`、`lhc::extract_archive_with_options` / `verify_archive_with_options`）を追加。作成はblock単位の並列圧縮で、worker数にかかわらず書庫のbyteは同一。展開・検証は全frame familyを並列復号できる。
- 公開前のfsyncを明示的に省く`--no-fsync`（`skip_fsync`）をLHCの作成・展開とLHAの展開へ追加。既定はfsyncを維持する。
- LHCに実験候補`portfolio-ppm-trial`（`BlockStrategy::PortfolioPpmTrial`、archive revision 11）を追加。revision 10の4方式へPPMII（PPMd var.H相当）の独自Rust実装によるテキスト候補（frame `LPM1BLK`）を加え、block単位で最小の完全frameを選ぶ。Calgaryの書庫は7-Zip LZMA2 mx9 solidの約0.913倍になるが、テキストblockの復号は遅くなる。既定`mdl`と既存revisionの読取は変更しない。
- LHC portfolio-trialのMDL重複計算を除き、MDL木選択の対数計算を表引きにして作成を高速化。出力の一致はCanterbury 11fileの書庫byte比較と、BinaryAdaptive基準の再利用を固定する単体テストで確認した。

- ABI 1のAPI level 6としてLH4作成と、LH4/LH5/LH6/LH7の明示的な高圧縮オプションをRust・C JSON・CLI・.NETへ追加。標準と2パス最適化の本文サイズを比較して小さい方を採用し、LH0は無圧縮を維持する。既定の標準圧縮と公開版1.0.4は変更しない。高圧縮は追加の時間・入力サイズ比例の作業メモリを必要とする。

## 1.0.4 - 2026-09-18

- ABI 1を維持したAPI level 5として、Rustの`visit_archive_entries*`、Cの`unlhare_list_entries_json`、.NETの`ArchiveClient.VisitEntries`を追加。一覧項目を書庫順に同期通知し、全件の`Entry`配列と集約JSONをnative側へ保持せず処理できるようにした。API level 5のnativeでは従来の.NET `List`も項目通知経路でmanaged側の結果だけを収集する。

## 1.0.3 - 2026-09-18

- ABI 1を維持したAPI level 4を追加し、直前のnativeエラーをI/O、書庫形式、非対応機能、上限、無効パス、既存出力、無効引数、キャンセルなどへ分類できるようにした。.NETでは`ArchiveNativeException.Kind`で公開する。
- .NETの通常の`ArchiveClient.List`もAPI level 3以上では同期JSON結果通知を使用し、利用者が追加オーバーロードを選ばなくても1回の書庫走査で一覧を取得するようにした。API level 2のnativeだけ従来の二段取得へフォールバックする。
- 結果通知版の圧縮へ`fail_if_all_skipped`を追加し、全入力が読めない場合に空書庫を公開せず失敗できるようにした。.NETの作成結果は文字列ではなく`ArchiveCreateEntryStatus`で公開する。
- WindowsとmacOSでは圧縮元・展開先の基点、書庫内の親ディレクトリ、書庫出力先の親をルートハンドルから1要素ずつ非追跡で開くようにした。Windowsでは中間のjunctionを含むreparse point、macOSでは利用者が作成した中間symlinkを拒否する。macOS標準の `/var`、`/tmp`、`/etc` はリンク先がOS既定の `/private/...` と一致する場合だけ物理パスへ正規化する。書庫の一時作成とno-replace公開も検査済み出力親ハンドルを基点にする。

## 1.0.2 - 2026-09-18

- ABI 1を維持したAPI level 3を追加。一覧の同期キャンセル、更新日時メタデータと通常ファイルの任意の時刻復元、入力I/Oエラーだけをスキップして項目ごとの結果を返す圧縮に対応。.NETにも既存メソッドを維持した追加APIを用意。
- 圧縮時の書庫内名でWindowsの相対パス区切りも受け入れ、正規化後に安全性と重複を検証。
- 圧縮元の読み込み中にCRCを計算し、対応CPUではSSE4.1/PCLMULQDQ・AVX-512/VPCLMULQDQまたはARM AES/PMULL命令を実行時に選択し、非対応CPUではソフトウェア実装へフォールバックするようにした。同一書庫ではLZSSエンコーダーと圧縮バッファを再利用し、LH0指定時と圧縮で大きくなる場合は入力バッファをそのまま書き込む。
- 圧縮元を検査してから読み込むまでの間にファイルやシンボリックリンクへ差し替えられても、別の内容をアーカイブしないようにした。ディレクトリ一括圧縮は基点ハンドル配下だけをたどる。
- 展開先の基点ディレクトリをシンボリックリンクやジャンクションへ差し替える競合を拒否するようにした。
- 書庫の事前検査から復号まで同じファイルハンドルを使用するようにした。読取時に書庫ファイルと項目メタデータの上限も追加し、差し替え競合と細工された巨大書庫による資源枯渇を抑止した。
- Windowsの予約デバイス名について、コンソール入出力名、0番、上付き数字、拡張子直前の空白を含む表記を全プラットフォームで拒否するようにした。
- LHAヘッダーのMS-DOS属性でシンボリックリンクと示された項目を、一覧・検査・展開で拒否するようにした。

## 1.0.1 - 2026-09-17

- ABI 1を維持してAPI level 2を追加。明示した入力一覧の圧縮、選択展開、上限指定、同期進捗通知とキャンセルに対応。
- Windows x64/ARM64 DLLとNative AOT対応C#ラッパーを含むNuGet `Kagayoi.UnLhaRe` を追加。
- ハードリンクが利用できないファイルシステムでも、検査済みデータを既存ファイルを置換せず展開。
- Lhamielがパッケージの版とlockfileを固定し、UnLhaReの公開後に参照更新・検証できる手順を追加。
- LH5/LH6/LH7の単一ファイル圧縮計算中はキャンセルを遅延して受け付ける制限を明記。

## 1.0.0 - 2026-09-17

- Windows・macOSのx64/ARM64向けに、64bit専用のLHAライブラリとCLIを初公開。
- Rust APIとUTF-8 C ABIを提供。旧UNLHA32の32bit ABIとは独立し、既存32bitアプリには互換版UnLha32Reを使用。
- 書庫一覧、本文サイズ・CRC検査、展開、新規圧縮（LH0/LH5/LH6/LH7）に対応。
- 日本語・絵文字の書庫名と階層、独立した並列呼び出し、既存出力を上書きしない操作を提供。
- Windowsは署名付きZIP、macOSは実行権限を保持するtar.gz、SHA-256一覧を配布。
