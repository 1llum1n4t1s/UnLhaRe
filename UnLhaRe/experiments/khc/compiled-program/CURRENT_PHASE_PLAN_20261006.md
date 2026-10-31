# 現Programのnative保存frame診断

2026-10-06 JST。前工程は現Release CLIの全書庫復号83.35/83.23ms対強solid7Zip40.86/41.53ms、率466395/481490B。元GOALは未達。旧pre-port CompactTreeのphase83%値を現Programへ転用しない。

現在のmod.rsを別namespaceへコピーし、14child pathと6境界時計/TLSだけ追加する。生成物からそれらを除いた正規化ソースが現modと一致することをcompile前に検査し、全child/公開rlib/入力/EXEをSHA・mtime・長さでpinする。新診断に型・アルゴリズム・validation省略・entry変更を混ぜない。

現公開archive verify/listを先に実行し、実466395B書庫の11frameをboundedに読む。各frameを現在の公開decompress_blockと診断namespaceでwarm1+9復号し、どちらも全byteを元corpusと直接比較。99有効行、phase合計<=total、非MDLのphaseは0、frame/原size/method、64MiB容量gateを照合する。native cold wall/純codec/診断時計の費用を区別する。

時計はwire、alphabet/Forest/CDF・Program reservation、grammar/setup（静的Program後のrange/履歴/出力準備）、token/runs+finish/drop Forest、inverse、CRC/capacityの6固定境界のみ。個別branchへ時計を入れない。method2/3の内訳は本診断では0なので、独立public totalとの差から推測でLZの内訳を作らない。

失敗先行: profile不一致/旧module・公開library借用違い/99件未満/fullbyte違い/phase合計矛盾/容量またはchild期限超過/入力pin変化は不成功。初回失敗後に上限を伸ばさず最小原因だけ是正し、別attemptと識別ソースへ保存する。

資源見積: helper EXE<=2MiB、単体rustc一時物<=4MiB、report<=128KiB、frame複製のdisk0。専用root8MiB、free5GiB+8MiB、codec/helper64MiB/compiler512MiB、child60秒/suite300秒、quiet15%/60秒。既存Cargo cap6175228536B/使用6169422158B、Cargo書込0、new target-dir/ダウンロード0。測定値は診断であり採用速度の証拠ではない。元GOALゲートを変更しない。

opop親担当: Performance/Testerは現在の正規化照合とpublic cross-decodeを採用、Hardeningはbounds/pins、Asyncはchild終端/read locks、Startupはcompile表/EXE費を計上、Normalizerは旧参照と現診断を明確分離、Cleanerは再現に不要な生成物のみ対象。Modernizer/Intelは依存・外部仕様判断なし/非該当。本工程の新subagentなし、製品source/API/wire/version変更なし。
