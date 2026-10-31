# CTS node-u32の正式比較結果

CPU条件で予備実行中に終了。正式測定9回は開始しておらず、速度中央値・採用・総合7-Zip超えは未証明。この試行はterminalとして保存し、同候補を自動再試行しない。

## 保存証拠と到達点

- comparer `cts-node-u32/compare.ps1`: SHA256 `80732F393EA0A5E2EBCA782AC2CB6623373CC8B3ECD40207A0AF2D4B6E9FA333`。旧comparerから9件の全文明示対応、65一意support pin、8計測helper AST不変を事前確認。
- report `../../build/khc-cts-node-u32-20261002/performance/report.json`: 1260048B、SHA256 `63AC1ACDF2700E936DE9E96A22F38F16C1E3E40E9ED12E107E381FA67D894FF1`。
- attempt `../../build/khc-cts-node-u32-20261002/performance-attempt.json`: 6082B、SHA256 `D4D04C5F8F9FBCCBDB05A6E2D7FB6DE7CCF43BD62E6CA4B763C75DC65EFB0C60`。
- report UTC 2026-10-01T19:50:28.4708556Z〜19:52:07.326581Z、status `failed`、理由 `Host CPU busy; no ordinary performance adoption allowed.`。

preflight5件の総CPUは0/0/5/0/8%で通過。今回は歴史proof closureまで実行し、2512 evidence files、2795 provenance records、8 helper AST、厳密な予算guard例外2件（narrow/wide）の照合を完了した。旧compact試行と異なり、closure未実施ではない。

7za versionと3方式の予備encode/decode、計7子processが記録された。最後のnative予備decode後、UTC19:51:44.2426224ZにCPU28%で上限15%を超過し終了。3 sample rowsはすべてwarmup、正式測定sampleは0。

## 予備観測の限界と次の判断

| 方式 | complete bytes | 予備encode wall | 予備decode検証 |
| --- | ---: | ---: | --- |
| node-u32 candidate | 483496 | 2929.7382ms | 直接復号・hash一致 |
| balanced control | 483469 | 3030.6148ms | 直接復号・hash一致 |
| 7za26.03 native | 483599 | 588.2126ms | CPU条件違反で検証未完了 |

候補の予備encode子CPUは2921.875msで、今回の単発観測ではCLI wallの大部分が子process処理だった。ただしwarmup1件を中央値へ読み替えず、速度改善率・勝利・正式ゲート合否の判定には使わない。native decode子processは終了記録があるが、post-CPU gateでthrowしたためその後の復元ファイル照合/SLT等は未完了。成功したnative E2Eとは扱わない。

候補frameは上限より103B小さい一方、単発予備encodeは固定目標574.5624msから大きく離れている。メモリ保存幅だけの改善では十分と見なせず、次は数値/モデル処理の計算量を減らす候補を優先する。この判断は正式中央値の証明ではなく、研究優先順位を決める限られた観測に基づく。

## 容量と不変条件

report保存後performance16765198B、親合計41352383B（約39.4MiB、attempt含む）。performance96MiB/親128MiBの予算内。report内のfinal budget15505150Bはreport自身の保存前。EXE・fixtureは再利用、Cargo/cache/PDB/raw trace新設なし。失敗理由の追跡と再現に必要な証拠は保持する。

観測器・初期化位置・CPU15%・サイズ483599B・速度574.5624ms未満・warmup1＋測定9・循環順・single-thread・時間境界は未変更。priority/affinity/power/他processの操作、旧terminal候補の再実行もしていない。初期化分離の提案は依然ユーザー確認待ちで、今回導入していない。

holdout/カテゴリ、同境界decode、四native、製品/API組込みと安全性も未完了。goalはactive。
