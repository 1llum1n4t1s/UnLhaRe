# full E2Eの事前identity訂正と新検証枠

元契約 `DIRECT_TOKEN_FULL_CONTRACT_20261002.md` SHA `874EE1F8F60572BF8DC06EF07AE565017B59B005A7196ABFBFEA1571C5556571` とcodec SHA `52AE4721BE40197A40F97DF9377F300986063649DCB8121B5A5516F376906512` は変更しない。

元検証入口はexit1でterminal。verifierのBWT pin参照先が `causal-bayes-fast-bwt/bwt.rs`、要求SHAは `810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F` だった。参照先の実SHAは `CE0B1E09C63D651A4AE0A35F8B406F9CBEAB02D54A1CD594037C20F3B665F14C`。codecが実際にimportする `causal-bayes-sais/bwt.rs` は要求SHAと一致する。親も現存sourceとimportを確認した。

停止時verifier SHA `99B54AADBF04861B5B7604F353F78E38ED16653E8D6CCD51D4E951C299593DE8`、forge `0892F905002D6776FD494D0587B8DDDB379BE13C97DED224F9382B753AA4204A`、failure plan `65F9B319794FAECDC2B6A5ECE477C6A4B5329E352658A9D0ACD6E711177EE44A`。元root `build/khc-direct-token-full-20261002` は未作成、compile0/codec0/生成物0byte、lock閉鎖、関連processなしを親が確認した。失敗はmetadata事前照合であり、compression/size/正式性能の結果ではない。元rootを使い回さない。

## 修正・実行前の追加照合

- verifierのBWT参照先を実importへ訂正し、本addendumと元契約両方をpin/read lockする。新fresh rootは `build/khc-direct-token-full-20261002-bwt-pin-fix`。予算64MiB/通常見込み3MiB/最悪50MiB、child120秒/出力65536/report512KiBは維持する。ownerは同じworkerで、親codecはfreezeを維持する。
- 固定サイズgateは元の上限 `<=483599byte` で記録する（verifierの `<` を `<=` へ合わせる）。速度/CPU/warmup/回数/計測境界を変更しない。このE2Eは正式性能測定ではない。
- 現存compiler/runtime/source/固定input/旧balanced EXEと旧empty frameは前後identityを照合する。旧EXEは既知SHA `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0` をpinする。
- 削除する小input/forge/boundary frameの記録は `transient_path` とSHA/bytes/deleted ledgerで表し、generic identity closureが現存証拠だと誤解する `path+sha256` を残さない。reference frameと実EXEはstable identityで保持する。CRC修復はケースごとの事実を記録し、intentional bad CRCやmagic/fieldsを全て `crc_repaired=true` と表現しない。
- no-clobberは既存output実byte/identity保持と `output create_new` stderrを確認する。独立zeros255/256/257のfullbyte境界検証を実行する。grammarがunique active listによって到達不能なnon-maximal adjacent拒否branchは、静的invariantの確認と実行済みcaseを区別する。
- 必要なworker source/plan訂正は実行前に一度まとめ、新SHAを通知してから一度実行する。同一条件の無制限再試行や上書き、旧測定候補の再評価、observer変更はしない。以降の失敗は報告・最小再現を残し原因確認する。

他の範囲、容量、安全なcleanup、Git/公開/x86の禁止、full goal未達/activeは元契約のまま。これはアルゴリズムの是正でも評価条件の緩和でもなく、未実行のfull検証入口のidentityと証拠分類の訂正である。
