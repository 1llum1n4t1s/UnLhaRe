# Windows native peak計測の限定照会

確認日2026-10-04。対象はRust1.98.1単体、Windows11 x64、packed-inverse私的診断の計時外一回読取り。製品依存追加/WinAPI公開ABI変更ではない。Intelを内部bit演算には起動せず、このWinAPIの構造体/値の意味だけ親が確認した。

## 問いと一次資料

問い：native自身からpeak working setを読む関数名とEX構造体のフィールド/値の意味は何か。新planのAPI追加前にコードだけでは決まらない外部ABIを照会した。

[Microsoft GetProcessMemoryInfo](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)（本文最終更新2022-02-01、専用Microsoft Learn fetchで全文確認）は、HANDLE/構造体pointer/DWORD cb、BOOL成功非zero/失敗zero、COUNTERS_EXも受理すること、Windows7以降のK32名がKernel32.dll/libでexportされることを示す。対象Win11にはこの形で該当。戻り失敗は取得不能としてOSerrorを記録し、メモリ使用ゼロへ変換しない。

[Microsoft PROCESS_MEMORY_COUNTERS_EX](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex)（本文最終更新2024-02-22、専用fetchで全文確認）はDWORD二個、その後SIZE_T九個を定義。順序はcb/PageFaultCount/PeakWorkingSetSize/WorkingSetSize/QuotaPeakPagedPoolUsage/QuotaPagedPoolUsage/QuotaPeakNonPagedPoolUsage/QuotaNonPagedPoolUsage/PagefileUsage/PeakPagefileUsage/PrivateUsage。PeakWorkingSetSizeはprocess全体のworking-set peak、PeakPagefileUsageは生涯private commit peakで、個別inverse/phaseのpeakや実pagefile格納量ではない。

x64 repr(C)80B/align8/最初SIZE_T offset8という値はこの定義とWindows x64の型幅から親が導出したもので、資料に書かれたsize値ではない。実Rust size/offsetを検査してからcallする。実buffer extentとcbを同じEXサイズにし、小さいbase構造体に大きいcbを渡さない。取得値をlogical配列capacity/推定quotaと混同しない。

## 準一次調査と境界

`gh search issues GetProcessMemoryInfo --repo microsoft/windows-rs --limit 5`で[issue3583](https://github.com/microsoft/windows-rs/issues/3583)（2025-04-23作成/closed）のEX2型アクセス相談が一件返り、本文を確認。対象はwindows-rs/EX2のergonomicsで、今回のraw EX宣言/Win11 APIが壊れる証拠ではない。本文にあるサイズの異なる構造体pointer例はユーザーの相談用コードであり、正しい割当/安全性を保証した資料ではなく採用しない。主張は公式ABIに限定し、GitHub検索で既知不具合が一件しかないことを安全の証明にしない。

最初のgh検索はrepo指定をqueryへ含めたPowerShell経路で不正queryとなり失敗した。--repoを分離して上記読取に成功した。未解決の外部仕様照会はなし、Reddit/X/Grokへの追加調査は不要。新Rust FFIの実行成功・peak値・160MiB資源判定・4nativeは未検証。親の外部調査はこの二API資料/一issue本文だけで、候補の速度採否を外部情報から決めない。
