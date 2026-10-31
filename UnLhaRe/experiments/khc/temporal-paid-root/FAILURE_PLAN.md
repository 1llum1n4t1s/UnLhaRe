# Paid root failure-first census

保存時点で実装・コンパイル・native実行は未着手。親PLAN SHA256 1FA09B573D7E2DA132CA5DEBF7FCCB0911D16AA05F2C77270E1D1BE7FAEB3C6D。

- 凍結temporal E2Eを直接参照する。65537境界、65536終了、24拒否と同一プロセス回復、実Front 3例を維持する。
- 正常packet有限fixtureは4例: 全default、各k非uniform weighted、深さ5までhistory依存、bit/byte境界。各例で完成packet厳密parse、852roots、全history CDFと独立weighted loss oracleを検証する。default k2/3/4は独立Hamilton算術を確認する。
- packet拒否は8例: 短い長field、0bit長、上限超過bit長、payload切詰め、余剰byte、非zero padding、低頻度CDF、depth5超過split。各拒否後に同じ正常packetを再parseして回復を確認する。
- root拒否は3例: 不正k、余剰bit、切詰め。weighted拒否は4例: prefix、tail、CAP、shape。拒否が状態を破壊せず正常入力へ回復することを確認する。
- 生産経路では各tile Dense clear前に284Hist/Fit/852rootを処理する。Fit→個別root parse全CDF、連結rootbit直接比較、完成packet全parseとDense row lossを別検査として記録する。node/component/tile DP loss差は1e-6bit以下。
- 失敗仮説は固定順混同、k3 default丸め、root間padding混入、tail/depth/CAP漏れ、packet長境界、weighted履歴向き、Dense clear順、Fit数値変更、無分割でないdefault省略、加算誤差、資源capacity過小見積り。
- max payload5052999 / field込み5053003B、Dense13959192B、固定14PaidStats、Hist/Fit/Dispatch/root/packet各1個。node loss/count oracle配列は284*(8+8)=4544B、reserve4MiB内。全tile forest/CDFtrace/packetファイルなし。
- workerは6source保存、非書込rustfmt syntax、元全文/可逆ledger確認で終了。compile/native/runner実測は親のみ。実frame0・速度/holdout/portable/adoption未達を維持する。

## 実装ledger（改行LF化以外）

paid_model: 原model全文prefix保持、`// Paid root extension`以降だけ追加。旧private Writer/write_node/Reader/parse_nodeを直接参照する。

tile_accumulator: 元tiles全文からの変更は次の4箇所だけ。逆変換で元全文へ戻る。

1. `pub dense...pub whole...`行の直後へ `pub paid: Vec<crate::packet::PaidStats>,` を追加。
2. constructorの `Ok(Self { dense: counts::Dense::new()?, tiles,` を、固定TILES paid try_reserve_exact/resizeと `tiles, paid,` に置換。
3. flushの `let mut summary...` 直前にevaluate_tile、paid.count==tile_coded確認、paid[current_tile]代入の3行を追加。既存record/history/scan/clear順は維持。
4. capacity_bytes末尾へpaid.capacity()*size_of::<PaidStats>()を追加。

packet ingest: 旧bundleの`pub fn ingest`開始から`pub fn append`直前まで全文コピーし、`model::`のみ`paid_model::`へ置換。数値・transactionality・historyの向きは維持。

probe: 元probeの直接module参照と全Meta/free-Q集計を維持。grammarとE2E元fixtureは凍結元path参照、tilesは新Accumulatorへalias。新paid集計、符号付きdelta、bounded capacityを追加。無料CDF gainとpaid費用を別fieldにする。

有限E2E census: 元24拒否+新8packet/3root/4weighted拒否、原Front3例、packet正常4例、完成packet全CDF4*284*3*1024=3489792、個別root4*3*1024=12288。全default packet111B。新有限oracleでは深さ5splitと独立算術lossを確認する。

資源式: scratch_peak=Dense+Hist+Fit+Dispatch+MAX_BYTES+Vec24+packet5053003+Packet32。model_working=scratch_peak+(Accumulator.capacity_bytes-Dense)+Summary+4MiB。node oracle4544Bと小stack値はreserveに含む。packet finishは同Vecへu32長fieldを書込みtruncateしcloneなし。E2Eの正常回復111Bとmalformed packet最大容量1個は同時保持するが、4MiB reserve内の111Bを加えても同上限内。通常packetは最大1個。
