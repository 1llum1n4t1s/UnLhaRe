# 次の問い：class共有で失うnode情報の費用込み利用可能性

## 確認できた結果と範囲

branch-history-mdlの親単一compile/nativeは成功したが、Q token532303B＋保存model7400B＋固定side3079B＝542782Bで、固定size483599Bより59183B超過した。headerを無料にしても535382B。全parsed CDF・DP loss・固定grammarが一致し、別言語で実headerの18roots/1542leaves/508splits/3810fields/59200bitsを照合した。これはin-sample loss screenであり、実coder・roundtrip・正式速度・holdoutではない。

当モデルのgroupはclass×合法prefixで、grammar.rsのwalkは木のnodeをcallbackへ渡していない。lookup-float-cts/model.rsはnodeを既存expertの条件とpoolの重みへ渡す。この差を次に切り分ける。新MDLの不足をnode混入だけが原因と断定しない。class×履歴5childを同じく保ったまま、component/node/prefix/historyを区別するとどれだけのtraining情報が残るか、まず保存model無しの楽観診断を行う価値がある。

## 次工程の限定した設計（まだ未実装）

1. 元Tree buildはvisibility/accessor以外変更しない。branch callbackへcomponentとnodeを追加するが、class履歴6本・更新順・prefix1更新・Front grammarを保存証拠と一致させる。
2. 深さ5の`component/node/prefix2..4/last10bit`全histogramをdense u32[4]で集計する。各行のsupport/tail/総数上限・checked加算・全coded branchとの総数一致を検査する。未観測rowはloss0で、現在tokenを条件keyへ入れない。
3. 全rowのempirical entropy（未観測支持を無料とする楽観値）と、同じHamilton/min2/Q32768のlossを算出し、side3079Bだけ加える。未来に学習した分布とmetadataを無料にするため、実候補ではなく必要条件の診断に限る。depth5全leafは任意のshallower suffix partitionを精細化するが、量子化後の単調改善は仮定しない。
4. 楽観sizeがなお483599Bより大きければ、このnode/historyだけの静的分布主経路を閉じる。通過しても成功扱いにせず、実model費用込みMDL設計と符号器を別工程で先に確定する。depth/precision/feature sweepは行わない。

## 資源と失敗条件

PowerShellの同cuts再帰による事前構造計算はalphabet257/256各142nodesを返したが、nativeのノード数照合は未実施。両component×142nodes×3prefix×1024histories×16Bのraw rowsは13959168B。これは論理配列費用で、allocator・inline・Front・input・BWTと実peakは別途予算化する。raw branch event Vec、input/frame/plain copy、Cargo buildは作らない。既存8MiBモデル予算で実MDL全nodeを一括保持できるとは言わず、次のコード前計画でphase/layoutを確定する。出力は引き続き8MiB以内、固定全体RAM160MiB・size/速度/正式比較条件は変更しない。

コード前に列挙すべき失敗はnode/component key alias、prefix1の履歴落ち、将来tokenの条件混入、全count不整合/overflow、合法support漏れ、loss有限性・丸め誤差、capacity過小見積り、実peak/tool/source identity変化、楽観値を実frame/総合勝利へ読み替えること。parentの手計算fixtureと小さい有限診断を先に決める。凍結branch-history-mdlと既存rootを再編集・再実行しない。

総合GOALはactive・未達。これは新たな停止記録ではなく、次実装へ引き継ぐ限定質問である。
