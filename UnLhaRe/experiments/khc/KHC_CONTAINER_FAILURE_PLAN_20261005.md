# KHC製品container：実装前の失敗条件

2026-10-05。親担当。既存LHA API/wire/dirty変更は不変。block担当とは新src/khc/block/の所有を分離する。

## 固定したwire

独立magic `KHC1ARC\0`、revision u8=1。32B header：magic[0..8]、revision[8]、flags[9]=0、reserved[10..12]=0、block limit u32LE[12..16]=1048576、entry count u32LE[16..20]、manifest bytes u32LE[20..24]、manifest CRC32[24..28]、header CRC32[28..32]（最初28B）。CRC32はISO-HDLC、認証ではない。

manifest上限4MiB。各record：UTF-8名前長u16LE、kind u8（0=file、1=directory）、flags u8=0、元長u64LE、mtime i64LE（Unix秒、i64::MIN=unknown）、名前。名前はportable canonical `/`、末尾slashなし。directory元長0。case-fold重複・file/child衝突は全manifest検査で拒否する。

file payloadは元長から決まるceil(size/1MiB)個のblock（各u32LE frame長＋KHC1BLK frame）、最後に全file CRC32 u32LE。空fileはblock0個＋CRC=0。directoryはpayloadなし。全entry後に `KHC1END\0`、その後にbyteがあれば拒否。frame元長は各分割の期待値に一致し、frame長は40..期待値+40。storedを含めて検証してからentry単位でno-replace公開する。後続entryが失敗した場合、先行公開entryは残る。書庫全体atomicとはしない。

Rust create/list/visit/verify/extract + progressとCLI khc-*を追加。listはbounded frame走査で一覧metadataを返すが復号・plain/file CRC検証をしない。verify/extractは完全復号。streaming visitorで全Entryの返却Vecを避けられるがmanifest検証用情報は保持する。source/output親は既存nofollow/root handle helper、staging/no-replaceを再利用する。archiveはregularで最終reparseも拒否。同期のみ、圧縮block計算途中にはcancel checkなし。

## E2E前に固定する失敗

- 正常：空書庫、空file、1byte、all256、UTF-8 nested、1MiB境界と複数block、stored random、全byte一致、既存LHA CLI回帰。
- 異常：magic/version/flags/blocklimit、manifest CRC/header CRC、entry count/name/mtime/kind/size、byte切断/末尾追加、block元長/extent/CRC、file CRC。
- 制限：entries/entry/total/metadata/memory上限を確保前に拒否、チェック付き加算、bounded depth128。モデルworkはblock decoderの固定branch/depth上限。
- 出力：全manifestのtraversal/case重複/file-child拒否、既存file維持、CRC失敗entry非公開、中間link/reparse非追跡、finalize直前競合file保持、cancel非公開。
- 入力：final/source親link拒否、scan後変更をmetadata/identity/lengthで拒否、出力先source木の中へ書かない。

追加E2E sourceはcodeより先に保存し正常・異常を別fileへ分離。実行後に成果物identity/結果を小さく保持する。専用E2E出力8MiB、共有build追加256MiB、空き5GiB+予算。code/build/native結果がまだない段階で成功やGOAL完了を主張しない。
