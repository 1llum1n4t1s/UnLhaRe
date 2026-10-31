# 固定7binのgeometry成立性（性能・実codec証拠ではない）

2026-10-06 JST。親がV8内の独立JavaScript geometryモデルで、固定grammarの142nodeを構築し全257limit/33153合法rankを調べた。旧routeと、7binから旧root/tail childを再構成して残subtreeへ戻るrouteが、node/class/child/prefixの列で全一致。旧root/tail履歴更新の整数式は全7bin×1024=7168履歴で一致した。

このモデルではroot child3から導出したtail nodeは2（lo4/class1）。番号は導出結果であり新実装のハードコード条件にしない。合成geometry中の有料tail吸収は32121組、implicit tailは10組だった。この分布は実ファイルの観測頻度ではなく、20%機会gateや性能改善の証拠に使わない。

readonly token_state_hotpath（要求/役割実効gpt-6.1-sol/medium）の独立ソース分析もmapping/historyを確認した。implicit limit1のroot0更新、limit5..8でrank>=4のtail0更新、bin6で32..側class1の追加更新を維持する必要がある。文法表を現在のcompiled Rustへ直接照合した新実行ではない。既存Programの独立有限検証の成功を、この未実装7値codecの成功に読み替えない。

次の最小実censusは、選択前context/prefix/binの6×256×7 u32 leaf histogram（43008B）、旧root/tail loss、厳密な有料tail吸収数、全旧有料区間数を保存する。節約数は `rank>=4 && active_len>=9` の件数であり、rank>=4全件ではない。20%分母は全旧有料grammar区間とし、escape込みの比も別記して両方20%以上を要求する。ROOT二つだけを分母にしない。

旧direct全257rank置換と同一ではない。旧same-class productも使わず、独立学習7値CDFが必要。ただし旧root/tail各5child履歴から各2childへ減る情報損失と、下位rank/length/inverseの費用が残る最強反証は未解消。k<=4/4要素/深さ5のpaid_modelをそのまま転用しない。新4ary depth4/341node/k2..7のDP・wire・Dispatch・parse容量/費用が必要で、情報・区間gateの不成立時はその実装へ進まない。

元GOAL active/未達。STRUCTURAL_RANK_PLAN_20261006.mdの次工程を具体化した記録であり、採用・新wire・7-Zip総合優位を意味しない。
