# 整数refinement正式比較: warmup中の静穏違反、中央値なし

初回正式比較は失敗として終了し、自動再試行していない。`build/khc-causal-integer-refinement-20261002-comparison-repair/performance/report.json` SHA `DA72625773F9FC16FF7691447367A29BF4832872354C980FFFC04F89CDE2C038`、attempt SHA `F3D4A0D19EB1ABE4C8031D2841E3A859A99CC8996811984B1BDC3DE7F46E32DE`。

2026-10-01T16:23:23.9725277Z〜16:24:53.0927732Z、status failed、原因 `Host CPU busy; no ordinary performance adoption allowed.`。preflight5回は0/5/2/2/1%で成功したが、旧balanced control warmup encode直後に16%を観測し、固定上限15%で停止した。計測9回のsamplesは0、paired比・encode median・採用結果はない。native7zaはversion確認のみで、圧縮比較まで到達していない。

## warmupの診断値（採用判断ではない）

| 呼出 | wall ms | child CPU ms | 完全出力 |
| --- | ---: | ---: | ---: |
| 新通常candidate encode round0 | 3380.9437 | 3328.125 | 483496B |
| 新candidate decode round0 | 3104.4172 | 3000.000 | 2811006B |
| 旧balanced control encode round0 | 3441.5225 | 3421.875 | 483469B |

新encode/decodeは前後静穏確認を通過し、完全frame SHAと直接復元SHAが成功した。旧encode後は16%で違反し、その行を有効な測定sampleにはしていない。これらはwarmup単発値で、正式medianや同session7-Zip比へ読み替えない。ただし新encodeのCPU時間がwallに近いため、起動待ちだけを理由に高速化済みとみなさず、演算量を引き続き調べる。固定574.5624msゲートは維持する。

## 計測/証拠/容量

- compare SHA `1BB00E71EB54CDDDAAC5146C5DC36F43B6F23F8FC37A9F0B5F1D3F546E800B51`、更新UTC2026-10-01T16:20:34.0450746Z（正本は実行report内script_last_write_utc）、CWD `C:\Users\IMT\dev\UnLhaRe\UnLhaRe`、bundled pwsh7.6.5、Windows x64/Ryzen5 7640HS 6C12T/rustc1.98.1。
- 旧compareから21明示置換の全文対応と8measurement helperのAST本文一致を確認した。time/CPU/thread/quiet/round/circular順/median式は変更していない。
- DFSで2174証拠ファイル、provenance2393の実行前後長さ/SHAが保持された。wide/narrow数値proofの2件だけは、契約済みcapacity guardの旧SHAから修正済みSHAへの対応をowner/path/role/両SHA/長さで確認し、reportへ記録した。他の不一致は許していない。
- rootは終了直前9399761B。新しいraw/ETL/全assembly/Cargo cacheはない。report/attemptを含む実測容量と残存は別途終了確認する。Drive空きは実行時約64.6GiBへ増えていたが、前回清掃以外の増加の原因は未調査で、この作業による回収量とは主張しない。
- 設定1threadとOS samplingは別証拠。warmupでは最大3〜4threadを観測し、active CPUの生涯単threadを証明したとは主張しない。poll要求1msに対して実最大間隔約32msであり、OS samplingの限界も残す。

## 次の問い

Bayesのlog2は既に表化されていたため、対数lookupが未最適化という初期仮説は棄却する。`Class::predict`のexp2/logistic/float混合は每bitに残る。Q15 componentが同じ場合や、累積loss差で少数componentの最大寄与が0.5CDF未満に確実に収まる場合、整数CDFをそのまま返せるかを独立の数学/数値/E2E契約で調べる。閾値をcodecサイズへfitするsweepは行わない。

整数refinementは正確さと有限完全codec同値を確認した研究候補であって、速度/holdout/四native/製品統合/総合7-Zip超えは未証明。goalはactiveのまま。
