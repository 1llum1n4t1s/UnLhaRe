# Q32正常比較の再開条件 — 2026-10-01

ユーザーの作業再開指示に基づく。前回は最初の子起動前65%で拒否（actual child0）、その後の3回限定診断では自己走査だけで負荷を説明できず、guard修正を見送った。前回の比較・診断・source・proofは不変で保持する。今回は別日の再開時にCPU formatted11%を観測、codec process0と凍結source/exe/proof SHA一致を確認しており、同じ状態でのblind連続再試行ではない。

この再開区間では新`build/khc-bwt-causal-bayes-q32-20260930/performance-20261001/`の1sessionだけを許可する。凍結compare `2D5C7D57A4940861D01AD1558D8A3E9A27217B80FF40D716BDB356506C29DD4B`、候補FBF35/controlSAIS9AC/native26.03、固定group18B8/2811006B、size<=483599B、strict full encode<574.5624ms、warmup1+9/circular39CLI/元preflight5・各子前後15%/allproofs689file readlockを一切変更しない。preflight取得失敗/負荷拒否なら新rootを作成せず終了、子前後拒否ならfailed reportを回収して終了、同再開区間で再試行しない。

性能が完走した場合のみ全raw/初回最終復元・11native metadata・stats/medians/paired ratios・provenanceとobserverを独立監査する。途中結果は通常性能/採用に使用しない。固定開発corpusの局所改善と、総合7-Zip超過/holdout/他OS/製品統合は区別する。新unit/API/version/deps/Git/外部公開/他process停止/priority/affinity/power/cache/UnLha32Re/registry変更なし。新sourceやbackupを複製しない。再開記録・report・初回最終/入力/復元は再現証拠として保持、不要中間は同一SHAを確認後receipt付きで清掃する。
