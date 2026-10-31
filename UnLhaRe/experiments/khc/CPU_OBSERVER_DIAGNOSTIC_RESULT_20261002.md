# CPU観測の読み取り専用診断結果

短い独立観測では総CPU約2〜7%だった。ただし、過去の正式比較preflightの26%の原因は特定できず、観測器の故障も証明していない。

証拠は `../../build/khc-cpu-observer-diagnostic-20261002/report.json`、26971B、SHA256 `2FE977F3E47D6C655382B09AC3476D84C4500322BEDA502649E71E779A6C8CFD`。UTC 2026-10-01T19:11:49.6720093Z〜19:11:59.6297969Z、論理CPU12、4窓で正常終了。正式性能ゲートとしては使用していない。

| 窓 | CIM照会 | native総CPU | CIM総CPU | CIM照会時間 |
| --- | --- | ---: | ---: | ---: |
| 1 | なし | 3.8188% | — | — |
| 2 | あり | 7.2398% | 9% | 599.9519ms |
| 3 | なし | 4.8638% | — | — |
| 4 | あり | 2.0752% | 2% | 274.2579ms |

native値はGetSystemTimesの2時点差分から計算した。kernelにidleが含まれる点とprocessor group制約は[Microsoft公式仕様](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)に従う。CIM値とは観測区間が異なり、差だけで故障を断定しない。CIMのtimestamp/frequency metadataは取得結果がnullで、cooked intervalの照合はできなかった。

process CPU寄与はPID・開始時刻が一致した取得可能processだけを差分計算した。保護・取得不能などのskipが各snapshotで89〜90件あり、原因帰属は部分的。診断PowerShell自身も総CPU換算約0.45〜3.16%の寄与があり、観測自身の負荷を隠していない。4窓の差は外部状態を制御した因果実験ではない。

凍結quiet observer、CPU上限、正式比較のsource/attemptは未変更。正式比較の再起動、他processの停止、priority/affinity/power変更はしていない。C#初期化はin-memory、raw trace/ETL/EXE/PDB/Cargo cacheなし。生成物は上記の小さなreportだけで、1MiB予算内。

この診断は現在も常に低CPUだという保証ではない。測定前初期化と証拠確認の分離を提案したが、同候補の新測定枠への再評価はユーザー確認待ち。
