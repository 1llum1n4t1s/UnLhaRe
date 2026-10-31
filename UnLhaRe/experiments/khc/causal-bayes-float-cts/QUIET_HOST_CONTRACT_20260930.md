# CPU飽和時の測定を採用しない — 再測定の事前契約

最初のperformanceは39 CLI/全frame/復元で成功したが、途中の2026-09-30T04:48:19.9188771ZにCPU100%、dotnet43/MSBuild5/node91/rustc3/VBCSCompiler2を実測。候補20388.3102ms/control15682.5238ms/native6697.4197msはこのcontended sessionの観測値で、通常の高速化採否へ使用しない。元report/sourceを上書きせず、resource-contention.jsonとともに保持する。correctness/sizeの検証は別で保持する。

新規compare-quiet.ps1は元compareのcopyへ静穏性の前提だけを追加する。固定size/time/corpus/native options/runs/source/proof pinsは変更しない。Get-CimInstance Win32_PerfFormattedData_PerfOS_ProcessorのName='_Total'で記録するCPU使用率が、preflight5回（間隔1秒）すべて15%以下であることを、新規work作成前に確認する。各child processの直前/直後にも同じ上限を検査し、一度でも違反/取得失敗/値異常なら通常性能測定成功を禁止する。quiet-host.ps1のProbeOnlyで、既存artifactへ変更せず同じ前提を確認できる。

この15%は機械負荷を制御する追加の測定前提であり、目標time<574.5624msの緩和ではない。CPU値は集計・観測windowを持つので、短い負荷spikeや個別processへの厳密帰属は保証しない。process count自体をbusy-core数やidle build-serverの活動証明にしない。他タスクの停止・priority/affinity・電源設定・環境変数・キャッシュ変更は行わない。quietになるまでのprobeだけでは圧縮性能達成としない。

先に拒否条件: CPU取得失敗/重複または欠落total/0..100外、5 preflight中1つでも>15、child前後の>15、観測sourceの途中変更、既存work上書き、同時codecの重複実行。失敗前に確認できたobserver実時刻/値をstdoutへ出し、子実行済みなら失敗reportにも保持する。active実行handleがある間は再起動しない。busyならrootを増殖せずProbeOnlyを使う。旧sessionのproofを新sourceへ読み替えない。
