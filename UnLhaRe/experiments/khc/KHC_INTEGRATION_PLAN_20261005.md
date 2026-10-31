# KHC 本体統合の境界と検証計画

最新GOALはRust 64bit版の実装・統合・比較を許可する。現行LHAの型・wire・既存dirty変更を維持し、新形式を別APIとCLIとして追加する。ここで示すインターフェース名は実装方針であり、実装済みの公開APIではない。

## 確認した接続点

| 役割 | 現在の接続点 | 統合方針 |
| --- | --- | --- |
| 名前空間 | `src/lib.rs`はLHA reader/writerを再export。Entryにcrc16/header_levelがある | 独立`pub mod khc`とKHC固有Entry/CreateOptionsを新設し、既存Method/CreateOptions/EntryへKHCを混ぜない |
| 実CLI | `src/main.rs`はcreate/list/test/extractとLH4/highの既存変更を持つ | `khc-create`、`khc-list`、`khc-test`、`khc-extract`を追加する。既存default/引数の意味は不変 |
| 元入力 | `directory.rs`のambient/beneath nofollow open | 保持root handleから読む。最終entryもregular/reparse/symlinkを明示検査し、pathだけの再openをしない |
| 出力親 | `create_ambient_directory_all_nofollow`、`create_directory_all_beneath_nofollow` | traversalや中間linkを拒否し、検査済み親handleを保持する |
| staging | `reader.rs`の`create_staging_file`はpub(crate) | `TempDir::new_in(&parent)`内のcontentを利用する。圧縮・CRC・length検証終了まで最終名を公開しない |
| no-replace公開 | `reader.rs`の`publish_staged_no_replace`はpub(crate) | hard-linkとOSのno-replace rename経路を再利用する。存在の事前検査だけに頼らない |
| filename | `pathname.rs::validate_entry_name` | 同じportable name規則、case衝突/file-child衝突の事前検査を適用する |
| limits | `Limits`にentries/entry/totalのみ | KHC固有optionsにblock/model/decode memory/work上限を加える。元Limitsをmemory予算へ読み替えない |

親が上記sourceを読み、独立explorerが9対象sourceのread-only調査で同じ入口を確認した。reader/archiveのFile::openはnofollowの元入力として再利用しない。writerの入力helperはprivateで全entryを保持するため、bounded block codecにそのまま移植しない。

## 形式と実用範囲

研究magicを永続形式のversion 1へ改名するだけの実装は行わない。モデル実費選択・全class静的化・bounded block/stored選択の検証後に独立magicとbyte単位仕様を決める。形式revisionとpackage versionは別で、Cargo/package versionは今回変えない。

任意の総入力は上限付きblockへ分ける。block境界のモデルresetと履歴を仕様で一致させる。固定group全体screenの結果を、そのまま小block製品の圧縮率として使わない。初期block候補は1MiB、作業領域の実要素capacityと最悪run数から再計算し、上限超過なら開始前に拒否する。採用前に連続group対小blockの圧縮率・時間・memoryを実測する。

stored blockには元byteをそのまま格納し、元長・checksum・末尾規則を他blockと同じ検査経路へ渡す。新APIは完全自己完結、CPUのみ、外部dictionary/model/network必須なし。長さとindexを信用して先に巨大確保しない。

最小製品範囲は独立Rust APIのcreate/list/verify/extract、実CLI、regular fileと明示directory、UTF-8名、元長・compressed長・時刻の契約である。timestampの範囲/精度は形式仕様に明示する。directory時刻復元、暗号化、SFX、追記更新は初期対象外。entry単位の検証後公開とし、後続entry失敗時に先行成功entryが残る保証を明示する。書庫全体のatomic extractを偽って約束しない。

新C/.NET ABIは最小Rust/CLI統合には必須にしない。後から追加する場合は新版AGENTSのheader/JSON/AOT契約をまとめて検証し、既存関数の意味を変えず新入口を追加する。

## 編集所有権

新codec/container/safetyモジュールの担当を一人に固定する。親はdirty `lib.rs`と`main.rs`の結線、必要なら保持rootのdirectory収集helperの共通化を担当する。移管は元担当READY/edit停止の後だけ行う。reader/directory/pathnameは既存crate内入口を再利用し、理由がなければ変更しない。既存LH4/CompressionEffort/high/.NET/FFI/test差分は戻さない。

## 実装前の失敗条件

- 空directory/空file、全256byte、UTF-8 nested、block境界±1、複数block、ランダム/既圧縮/storedをreal CLIとRust APIで往復する。
- magic/version/必須feature/長さ/checksum/モデル/CDF/終端/padding/trailingを破損させ、test/extractが安全に拒否し対象entryを公開しない。
- サイズ/entry/total/block/memory/work上限、加算overflow、truncation全位置、取消はallocationや最終公開前に拒否する。
- traversal、絶対名、Windows特殊名、case重複、file/child衝突、中間reparse/symlink、source link、archive親linkを検証し、外のsentinelを保持する。
- 元書庫と展開先が既存、または公開直前に競合fileを作成した場合、no-replaceが失敗して内容を保持する。
- LHAの既存CLI/公開API/FFI/.NETを含む対象build・静的検査・既存E2Eの回帰を確認する。

この一覧を先にE2E契約へ固定し、後から都合よく異常ケースを削らない。有限テストの成功と、全入力に対する形式の可逆性の説明を分ける。実行成果物は小さいmanifest/設定/hash/測定結果を保存し、大量の展開物やtraceを残さない。

## 残作業

全class試作の実native検証、完成frame/stored/逆BWT、byte仕様、新API/CLI統合、自動E2E、現行/Zstd/LZMA2比較、ablation、holdout、4環境native、README/設計/依存告知は未完了である。今回のsource調査や計画保存を、実装GOAL完了の代わりにしない。
