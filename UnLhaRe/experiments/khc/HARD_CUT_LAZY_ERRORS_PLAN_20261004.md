# Hard-cut成功時エラー構築の因果検証

## 問いと範囲

凍結engine.rs SHA DE6FEF9D31610F9A39513F5188F013C60D78613A13DA7FC892D37CA6CD770AE9 の2箇所だけ、ok_or(String)をok_or_elseにする。数値・state更新順・error textを変えず、実行時allocationと速度へ影響するかを調べる。model.rsなどの同原因3箇所は今回変更しない。正式速度/総合GOAL条件を緩めない。

## 実装前の失敗と検証契約

- source差分が2置換以外、依存/pin変化、予算超過なら実行しない。
- 旧/新の全frame byteが違えば失敗。ハッシュだけで同値を主張しない。
- 旧/新の全2811006B plain直接比較、各encode/decode typed Proof14全Eq、両側stats/debug Proof14一致が必要。cross-type debug比較をtyped Eqと混同しない。
- 有限14正常/34破損/4短headerを両側で保つ。旧primaryの正常160/価格/8190node全比較と拒否15/CAPexactを必要に応じ既存fixtureで候補にも適用する。post-code unit testは作らない。
- allocationの成功時除去をLLVMが既にしている可能性が最強反証。instrumented専用診断で両側のalloc/alloc_zeroed/realloc実呼出しを測る。カウンタはatomic、測定対象区間外のprint/I/Oを除外。allocation計測付き時間を正式速度に流用しない。
- 同一private processで2codecを独立scopeへ接続する際、codec差分はimport lineのscope化のみ、既存Model/codec/math/価格は固定する。candidate engine2置換以外の数式変更なし。
- allocation同数なら性能候補として不採用または証拠不足。減少しても正式速度改善と断言しない。実frame一致が崩れれば不採用。

## 資源・工程

source300KiB/EXE1MiB/report256KiB、新出力root build/khc-hard-cut-lazy-errors-20261004 最大8MiB、空き5GiB。共有Cargo/製品/x86/旧証拠/公開API/version/Git/外部変更なし。生frame/plain/input/tracesを保存しない。原engine/wire rootを編集しない。

第一段階は新hard-cut-lazy-errors/FAILURE_PLAN.mdと比較fixture/probeの仕様・sourceだけ保存、実装engine/codec/runner・compile/native禁止。親レビューとfreeze後、第二段階の所有範囲と許可を別途明示する。固定条件を勝手に緩和せず、計測結果に応じ次の正式比較を選ぶ。
