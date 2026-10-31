# 逆数補正候補の正式試行結果: CPU条件で停止

一度の新候補試行はterminal。preflightの総CPUは0/2/3/2/1%で通過し、source/history確認後に7za versionと候補のwarmup encodeが実行された。encode終了直後の総CPU16%が固定上限15%を超え、停止した。同候補を自動再試行していない。CPU16%の原因を外部負荷・計測器・候補のいずれかに特定したとは扱わない。

| 実際に完了した範囲 | 結果 |
| --- | --- |
| source事前確認 | 旧comparerから9明示置換。8計測helper ASTとround loopは不変、95support pinsは一致 |
| preflight | 5サンプル通過、quiet-host.ps1/初期化位置/15%を維持 |
| history/source closure | 2635 file、3027 provenance record、before/after SHA・長さ不一致0。wide/narrow budget guardの限定例外2件を維持 |
| CLI | 7za i 1回、候補warmup encode 1回、exit0。control encode/native encode/decodeは未実行 |
| 圧縮出力 | 483496B / CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。検証済みframeと同一SHA |
| 正式測定 | measured0、completed sample0。decode/9round/中央値/改善率/採用判断は未成立 |

候補warmupの記録はwall3118.6565ms、child CPU3062.5ms。これは**CPU条件違反のある単発warmupで、正式中央値・改善率・達成証拠ではない**。別sessionの過去warmupと比べて速い/遅いとは判定しない。ただし現在の厳しい574.5624ms全CLI目標に対して、この商推定置換だけで達成した証拠はなく、次はイベント当たりの計算そのものを減らす案を優先する。

## 保存した証拠

- 契約 `RECIPROCAL_CODEC_PERFORMANCE_CONTRACT_20261002.md`: SHA256 `E2F651C6366B511C63445D16697C176457E96D96C03629569532635219F849F2`
- comparer `reciprocal-codec/compare.ps1`: `FC5926AC7CCFCA13D2CC4BC96E1E6737574967E7CB371922F99783D97B9789AC`
- runner `reciprocal-codec/run-performance.ps1`: `E90E215AF92B49C7B39CC8D58E9F2ED0EAD1277E2398284D3596993D92A40BB4`
- source correspondence: `DFD171964511C70C3E66E7CD7100E9F1672AF3D71E31226203EE6816973C81F4`
- support pin表: `A77D1995B4EE0C21C26548B7DDBFEA38BBD48C583E50483A37C4D7D0080649B7`
- `../../build/khc-reciprocal-codec-20261002/performance/report.json`: `93EC69B9FAB0EF8C695E5F63F25A5FFB8468FD28E61B90EA75E204C534CD0B21`、1340914B
- `../../build/khc-reciprocal-codec-20261002/performance-attempt.json`: `38886F59EB04847470014F6AD81BA87B0808C4F71AB9F2BBA3A2816989893A61`、3650B
- attempt UTC: 2026-10-01T21:37:35.2285031Z～21:39:16.036816Z。record/argv/runtime/観測値・CPU/スレッド標本はreport内。

reportの新full比較台帳72件では、削除済みscratch71件をpersistent file closureから限定的に除外し、全比較相手のcurrent hash/bytes・保持frame1件・successful CLIのoutput path件数へbindした。固定frame以外を消している事実を隠さず、stable466 identitiesはhistory closureへ追加した。

## 容量・残作業

performanceは14files/7446200B（約7.101MiB）で48MiB予算内。親full+performance+attemptは9457901B（約9.020MiB）で64MiB予算内。PDB/tmp/ETL/reparseは0。今回は再現に必要な11input snapshot・group・frame・失敗report/attemptを保持し、共有cacheや他版に触れていない。削除可能な未参照一時物は残っていない。

確認待ちのobserver初期化分離は実施していない。固定ゲートを緩めず、未完了roundを中央値へ読み替えない。新数値・full correctness成功は維持するが、本候補の性能採用はしない。goalはactiveで、正式速度、holdout/カテゴリ、同境界decode、四native、製品/API組込みと安全性は未達。

次のderived comparerで直す事項: 旧KT reciprocal metadataと新batch metadataが同じreport key `reciprocal_proofs`を使い、新batchの項目が上書きしている。旧proof validation/history closureは実行・保存されているが、旧named pointerのreport表示は残っていない。今回の測定済みcomparer/reportはSHA証拠として変更せず、次候補では新batch専用keyへ分離する。計測helperや観測条件を変更する理由にはしない。
