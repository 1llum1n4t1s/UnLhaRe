# CPU観測値の診断条件（性能採用に使用しない）

native32性能試行はwarmup3/測定0、7zip metadata後のformatted CPU41%でfailed。失敗proof SHA `A288FFF42354EA71825CAFE142F27BAEBC0B2E07C10A35F6F97D45564BB8EAE2`、guard/thresholdを維持し再試行しない。41%の因果を既知とは扱わない。

仮説: 単発Get-CimInstanceによるformatted観測と明示時間差のCPU利用率が一致しない場合がある。反証: 明示raw WMI二点差・GetSystemTimes二点差でも同じ区間に15%超を観測する、又はfreshness/time-window差だけで説明できるなら、formattedの不具合とは判定しない。

[Microsoft WMI資料](https://learn.microsoft.com/en-us/windows/win32/wmisdk/monitoring-performance-data)はraw PercentProcessorTimeとTimestamp_Sys100NSの二点から100*(1-deltaIdle/deltaTime)を示し、formattedデータのrefresher/baselineにも言及する。[GetSystemTimes資料](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)ではkernelがidleを含み、64logical以下は全processor合計である。独立APIのCPUは100*(deltaKernel+deltaUser-deltaIdle)/(deltaKernel+deltaUser)とする。

親が新host-counter-crosscheck.ps1を所有し、Windows x64・logical1..64で6区間の通常idle診断を一度実行する。各区間のnative/raw時刻と生counter、formatted値/取得時刻、process CPU差の参考値を保存する。CIM/APIの窓は完全同一ではなく、formattedの内部区間は不明。独立診断は性能guard代替/過去41%の否定/高速化証明には用いない。

失敗条件: API/CIM取得失敗、Total欠落/重複、counter/timestamp非単調、delta0、非finite/範囲外値、source/contract変更、既存出力上書き、診断報告欠落。raw/CPU値をclampしてエラーを隠さない。外部設定・process停止・レジストリ・CPU負荷生成・threshold変更なし。新root build/khc-host-counter-crosscheck-20261001に生counter/結果をCreateNewで保持する。
