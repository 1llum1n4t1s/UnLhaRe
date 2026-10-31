# 次の全書庫評価：サイズと完全復元の入口

2026-10-06 JST。CDF高速化は初回5.46%短縮、逆順0.07%短縮で既定screen不成立。製品へ接続せず、同種micro候補を繰返さず、未達の全書庫ゲートに直接関係する比較へ移る。

## 先行失敗条件・評価範囲

固定11development計2810784Bだけを利用する。KHC製品CLI binary-adaptiveの実書庫と、固定7-Zip26.03のnative 7z/LZMA2/solid/1worker/mx9/md4m/mfb273を作成する。4MiB辞書は全入力総和より大きい。メタデータを含む書庫の総byteを課金し、単体frame合計やXZと取り違えない。KHCは現仕様のentryごとの独立blockでsolidを持たないことも明記する。7zのSolid+/Blocks1/Method LZMA2:22を実listingで確認する。

双方についてnative test、実extract、11個全filename/extent/byte/mtimeを照合する。不足・余分なファイル・reparse・guard超過・exit非0・pin変更を失敗とする。byteは各fileのbase64完全比較（可逆写像）＋SHA記録、KHCのmtimeは現形式の秒精度で比較、7zは100ns精度。sourceを変更/コピーしない。出力は未使用専用root、上書き入力や既存archiveのupdateを行わない。

今回は各方式1回だけのサイズ/完全復元診断であり、時間値は参考で勝利証拠ではない。9paired＋逆順、真正未見、Zstd/他7Zip方式、代表複数種、公平な最大RAMの全GOAL判定は未実施のまま。サイズが不利ならその構造上の不足を次候補の根拠にする。現CLIは既存Release EXEをSHA固定し、ソース固定と既存9E2Eの継続性は確認するが、新compileのprovenanceを作ったとは称さない。

## 資源・保存

専用work8MiB、見積復元2×2810784B＋archive各上限1MiB＋report128KiB=約7.5MiB、原入力は再利用。archiveサイズが1MiBを超えればextract前に拒否。rawコピーの一括downloadやCargo再buildなし。source/pins/protocol/小report/2実archiveは再現成果物として保持。検証後の今回復元2directory（5.36MiB）は指定module窓口でごみ箱→今回分purge→不在確認、台帳を保存する。途中失敗は証拠を保持する。

CPU quiet15%/60秒、child60秒/suite300秒、各native private/WS64MiB、空き5GiB＋8MiB、report128KiB。観測guardであり真のpeakの保証ではない。親が全実装/判定を所有、Git/公開/version/共有cache/他版/削除hookを変更しない。

外部一次確認（2026-10-06）：公式repoの26.03 commit <https://github.com/ip7z/7zip/commit/0766b73>。manual raw URLは404で参照できなかったため、未取得のmanualに依存せず実EXE受理とtechnical listingで使用設定を確認する。
