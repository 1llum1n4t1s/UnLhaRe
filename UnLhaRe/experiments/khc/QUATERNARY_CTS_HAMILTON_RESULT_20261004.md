# Hamilton必要分選択の結果：不採用

数値・拒否契約と全E2Eは成功したが、固定ABBA1周で両方向短縮を満たさなかった。元depthの通常経路を維持し、候補は採用しない。同条件で再試行しない。7-Zip総合目標は未達。

| 2標本中央値（呼出内診断） | 旧 | 新 | 差 |
| --- | ---: | ---: | ---: |
| encode | 5774.9763 ms | 6113.21015 ms | +5.856887% |
| decode | 5760.4176 ms | 5816.925 ms | +0.980960% |

旧→新→新→旧、warmup0、ABBA1周。呼出内時間で、正式全CLI/quiet CPU/同境界7-Zip比較ではない。code配置・scheduling・少数標本の影響があるため原因は断定しないが、今回の次段条件は不成立。小sortが既に最適化され得るという反証を覆せなかった。

## 実装と検証

- private新root7file90249B。元depth CTSを複製し、kt/normalize_q2の選択2blockのみleft0skip/left1argmax/left>=2旧sortへ変更。逆復元allowlistは元全source exact。除算・guards・checked increment・Snapshot/更新は凍結。両codecはkt-equal templateとexact（候補CTS本文にはequalmass処理なし）。
- 独立analystが数値tie/error順、mutable repair/state、runner期限・容量を検証。編集中のformat引数不整合は実行前に修正・readback。worker停止・所有権返却後に親が実行、ユニットテスト・製品変更なし。
- compile1回3130.1033ms、契約CLI1回165.4229ms、ABBA CLI1回47146.4066ms、全exit0/timeoutfalse/outputoverflowfalse。stdout最大15696B、stderrはcompile warning997B、CLI0。
- KT全vector/error直接比較17320件（正常17262/拒否58）。mixture全vector/masses/error比較4137件（正常4126/拒否11）。left0/1/2/3件数 `[1040,1755,1165,166]`、left1最大余りtie3件。これらは契約入力の分布でありcorpusの実行分布ではない。
- 旧/新model tuple双方14/16/1、拒否state保持32 assertions。CTS旧新正常/foreign-certified visibleを現在値へ全修復後の受理4、stale/derived/未使用Kernel tail拒否6、全Cts Eq状態比較成功。
- encode4/decode4、全plain2811006B×4、全frame478750B×3=1436250B、全Proof14field/CDF bitsとstats22fieldを直接比較。inputread1、最大frame2/957500B、終了reference0、diskコピーなし。
- graph14、224 identitiesをbefore/after/live照合、親もEXE込み225件を終了後再照合、不一致0。所有EXE process0。timeout/pipe overflowの実fault注入は未検証。

## 固定証拠と容量

生成root `build/khc-quaternary-cts-hamilton-select-20261004/`、2file518828B（約507KiB）、8MiB上限内。空き約68.59GiB。削除なし。

- report.json: 89772B、SHA256 `72B4C384DE9F2ACD36E06B2411730AE384C31196691976F07F6827B9718F7E9F`。
- hamilton-select-o2.exe: 429056B、SHA256 `6C64C3EE5A6A832AD253C6C22F003C45556F66A43884D5F56167267261A744B7`。
- 入口 `quaternary-cts-hamilton-select/verify.ps1`。既存root上書き・再実行は拒否。

次の主経路は `COMPRESSION_GAP_DECISION_20261004.md`。Kernel微修正の成立を総合性能へすり替えず、より近いBT5/Beamの候補生成＋状態展開の構造削減を優先して検討する。固定size/正式encode/decode/CPU、独立holdout、同memory/thread、完成書庫・4native・製品APIは未達のまま維持する。
