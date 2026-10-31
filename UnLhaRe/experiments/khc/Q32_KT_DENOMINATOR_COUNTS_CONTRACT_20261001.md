# 実KT分母分布のcfg診断とE2E条件

前回goal作業は正式比較のfailed proof・独立CPU二点差・既に最適化済みのKT専用化棄却という証拠がありprogress。CPU負荷はtimingを妨げるが本件の正確性/件数診断を妨げず、impasseではない。

親が新 `causal-bayes-q32-kt-denominator-counts/{cts_model.rs,codec.rs,diagnose.ps1}` の編集を所有する。元operation-counts CTS/codec/診断scriptを再利用し、helper pathを凍結native32へ、診断cfgをkhc_kt_denominator_countsへ変える。通常演算はcurrent native32 CTS/codecと対応し、診断cfgを除いての全文比較を維持する。通常EXEと診断EXEをrustc1.98.1/native/ed2024/panicabort/opt3でcompileする。

件数はTree::predictの成功したNode::kt直後に採る。既存kt_calls/balanced_kt等7scalarを保持し、non-equal（実商計算）だけd=zero+one+1の5つの排他的binsを増やす。binsは2..63、64..255、256..4095、4096..65536、65537以上。equal shortcutをtable候補に含めない。診断はcount overflowで失敗し、通常cfgへcounterを入れない。Node/Prediction layout、通常予測/更新/書庫/CRCは変更しない。

実装前の失敗条件:

- helper/source/契約/使用する直接親proof/compiler/group/frozen frameの長さSHA/readhold/after照合欠落。通常source対応、compile又は120秒子期限の失敗。
- bins長さ5以外、負値/非整数、sum!=kt_calls-balanced_kt、各classのsumがtotalと不一致。実kt_calls!=17*bits又は旧7scalarが旧operation-counts proofと異なる。diag2回JSON不一致。
- 通常EXE/diag2回のfixed frame全byteが旧frameと異なる、encode Stats不一致、diag frameの復号が2811006B groupと異なる、既存outputをnormal/diagが置換。所有tmp残存。
- quiet失敗試行のwarmup値やdiag時間を高速化/採用へ用いる。fixed thresholdを変更、既存root上書き、自動retry、製品/API/x86/外部/Gitstagecommitpush作業。

新work `build/khc-q32-kt-denominator-counts-20261001` にreport、source/current identities、compile/CLI invocations、7class/total、全raw frame/復号/no-clobber sentinelを保持する。元diagnoseのStaticOnly入口を維持し、数学を変えないsource対応を実行前にも確認する。本件ではtableは未実装。実分布は適用可能性の証拠であって速度採用の証拠ではない。
