# 現hard-cut計器：phase1 実装引継ぎ

先行失敗契約の保存後、3ファイルの実装が完了し、workerの全編集停止・所有権返却を受領。親は3ファイル全文と末尾差分、各SHAを確認した。動的検証はまだ実施していない。

| ファイル | bytes | SHA256 |
| --- | ---: | --- |
| hard-cut-stage-profile/FAILURE_PLAN.md | 5633 | 4ACA1984AC424DC46E754905D37627D967C6F5F409F42E7F28665BCFD36D6A6B |
| hard-cut-stage-profile/profile.rs | 15123 | 9E793F95CAE6007E3E9405C169D115277897627D42419ADFFF91361D050C3491 |
| hard-cut-stage-profile/profile_e2e.rs | 10098 | 9F8E2027A69C2335C41033C9B34650563BC3AD2F43EECD50963158405350EC17 |

要求/役割実効worker-high / gpt-6.1-sol / high。非書込rustfmt2件exit0、compile/native/verifier0。profiler+fixture25221B。64KiBのState compile assertはソースに存在するが、compileでまだ実行していない。15有限合成fixtureの期待件数は未実行と区別する。未使用出力root0B、先行guard空き58120273920B。削除・Git・外部操作なし。

親の確認でinline audit moduleが凍結Source parserに非対応と指摘し、workerは追加ファイルやparser緩和でなくtop-level audit_*関数へ統一した。sticky fault検査と未終了検査の優先順、branch7件/abort6/recovery1、stage attempts[7,6,4,2]、negative residualは3−4、panic hookの限定退避・復元をコードで確認。これらの実際の遵守はnative未実行。

## 次段の固定接続

同workerへcodec.rs/lazy_model.rs/float_scope.rs/probe.rs/run-native.ps1の5ファイルだけを委任。phase1の3ファイルは凍結し、Modelの数値型・guard・状態を変更しない4呼出hookとcodec所有RAII、BWT/inverse/constructor低頻度wholeを接続する。親が最終READYを回収・レビューするまでcompile/native禁止。

Model.audit.prefixesの独立readbackはprobeのCell副帳簿へ保存し、8層commit件数と実Model集計を照合する。副帳簿・保持snapshotも64KiB計器boundへ含める。新しい入力検査をnumeric Result経路へ追加せず、差分は操作後の診断判定とする。

selfcheck stdoutは厳密に2 NDJSON records：計器15fixture＋実codec lifecycle/prefix1/truncated/recoveryの記録1、元finite14/34/4とmemory1。凍結元E2Eを書き換えて結果欄を挿入しない。実codec追加は、lifecycle三連実行、空prefix1、LCG4096 truncationと同process空復帰の3群に固定。各群内の実encode/decode数はrunnerで照合する。

固定profileではread1/disabled encode1/enabled encode1/decode1、全frame/plain/Proof14/statsを直接比較、参照frameは比較後drop。参照はdisabled同本文であり独立実装oracleではない。branchのclockはsampleのみ、TLS/counterは全枝に入るため擾乱を除去した純kernel時間と呼ばない。推計合計のwhole超過を0へ丸めない。

元通常目標やsize/quiet/warm1+9/holdout/完成書庫/API/4nativeは維持し未達。phase2実装と実計測へ継続、GOAL active。
