# CPU観測の読み取り専用診断: 実装前失敗計画

新compact fullの正式比較は2026-10-01T19:04:06Z preflight総CPU26%でterminal、codec CLI0件。候補の再試行、quiet-host.ps1/固定ゲートの変更、他process/CPU設定の変更はしない。今回の目的は現在の負荷と観測の妥当性を確認し、次の安全な行動を決めること。

1. CPU種別/分母の混同: Microsoft公式GetSystemTimesのkernelはidleを含む。2時点の(Δkernel+Δuser-Δidle)/(Δkernel+Δuser)をnative busy%とし、ticksは100ns。論理CPU64超ではprocessor group制約があるためこの診断を拒否。process CPU差分は別の実wall intervalと論理CPU数で正規化し、nativeと厳密一致すると主張しない。
2. WMI値が同じ区間だと誤認: 凍結observerと同じCIM class/filter/propertyを読み、query開始/終了/所要msと取得値/時刻metadataを保存する。nativeとは取得窓が異なるので単一の差だけで故障と断定しない。
3. 観測自身が負荷を作る: Add-Typeの初期化を測定窓の前に終え、without-CIM/with-CIM各2回、native窓2000ms以上でprocess CPU差分を取得する。自身のPowerShellとWmiPrvSE等の寄与も隠さず上位10件を記録。外部状態は制御しないためA/Bの因果確定やCPU静穏合格への読み替えは禁止。
4. PID再利用/exit/保護process/計算異常: 2時点のPID/開始ticksが一致したprocessだけ比較。取得不能/新規/終了は件数を残し、不明を0CPUとしない。native API失敗、nonmonotonic/zero total、負idle/idle>total、NaNなどはfailed report。process commandline/秘密値は採取しない。
5. 一時物/巨大dump: build/khc-cpu-observer-diagnostic-20261002、1MiB guard、sourceはapply_patch。C#はAdd-Type in memoryだけ、raw trace/ETL/Cargo/PDB/EXEなし。4窓×top10とbounded errorだけをJSONへ保存、fresh root一回/上書きなし。
6. 結論の拡張: 現在の短い読み取り観測は、過去26%の真因/候補速度/中央値/7-Zip超えの証明ではない。既存formal attemptはterminalのまま残し、observerや契約の修正が必要かどうかは証拠から別判断する。

公式参照: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes 。kernel含idle、100ns、64processor/group境界を確認した。Win32_PerfFormattedData_PerfOS_Processorは実CIM metadata/凍結observerとの対応も記録する。
