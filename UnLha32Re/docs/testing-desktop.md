# 検証用デスクトップ

`scripts/test.ps1` はビルド後、検証全体を `DesktopRunner.exe` の非表示デスクトップで実行します。
`CompatibilityTests.exe` の直接実行も、DLL のロード前に同じ方式で自身を再起動します。
製品 DLL のダイアログや検証するコマンドを無効化せず、表示先だけを分離します。
分離失敗時は通常デスクトップへフォールバックせず、エラーで停止します。

検証用プロセスでは HKCU も既定で空の一時キーへ切り替え、DLL が利用者の設定を読み書きしないようにします。
設定を与える試験は `--registry 'C:OverWriteMode=1'` のように指定し、
`--registry-dump` は同じ一時設定の実行後の値を出力します。一時キーは終了時に削除します。
レジストリの再読み取り・状態変更専用プローブは、従来どおり `--registry` の明示指定が必要です。
これは検証プログラムの規則であり、製品 DLL の設定保存先や設定動作は変更しません。

任意の診断スクリプトも、実行ファイルの絶対パスを指定して分離できます。

```powershell
$runner = (Resolve-Path .\artifacts\Release\DesktopRunner.exe).Path
$shell = (Get-Command pwsh).Source
& $runner $shell -NoProfile -File .\build\probe-legacy-check.ps1 <診断用の引数>
```

`--timeout-seconds 60` を実行ファイルの前に指定すると、時間制限を設けられます。
時間切れは終了コード 124、起動・隔離失敗は 125、それ以外は子プロセスの終了コードです。
通常の終了・ランナー停止時には、ジョブに属する子孫プロセスも終了します。
`-IsolatedChild` は `test.ps1` 内部用であり、通常デスクトップで指定すると検証を開始しません。

全体試験が失敗した場合は、診断に必要な入力・出力・一時書庫を生成先に残し、
`Failed integration workspace retained:` にその絶対パスを表示します。
正常終了した試験用ディレクトリーだけを自動削除します。期待値は緩和しません。
共有・freshen・圧縮順序・Wide圧縮選択の個別試験では、原版の `execute_cmd (MoveFile)`、戻り値32792、
システムエラー5がそろった場合に限り、初期書庫・入力・パス長をそろえた別領域で最大5回再試行します。
各試行の入力・出力・終了コードを保存し、原因未確定の原版エラーと正常比較の結果を区別します。
候補側の失敗、他のエラー、時間切れにはこの再試行を適用しません。

分離の確認には、非表示側で実際の確認ダイアログを出して自動終了する診断を使います。

```powershell
& $runner --timeout-seconds 10 $runner --probe-dialog
```

実装は [CreateDesktopW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createdesktopw) と
[STARTUPINFOW.lpDesktop](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-startupinfow) を使用します。
表示デスクトップを切り替える操作は行いません。
これはウィンドウ表示の分離であり、ファイル・ネットワークのセキュリティサンドボックスではありません。

## 進捗表示と小分けの検証

修正ごとの対象選択、CRCダイアログの重点確認、結果の再利用条件は
[検証の選択と完了条件](verification-strategy.md) を参照してください。

非表示デスクトップでも、原版 DLL の進捗ダイアログ自体は生成・更新されます。
`-gm1` はエラーメッセージの抑止であり、進捗表示の抑止は `-n1` です。
通常の `scripts/test.ps1` は、隔離試験の開始前から終了後まで、同じセッションの DWM を
別の監視プロセスで計測します。約2秒間隔で、1論理コアを100%とする CPU 使用率を計算し、
80%以上が5回連続した場合は継続高負荷として記録します。DWM の PID が変わった場合は
差分計算と連続回数をリセットします。試験が失敗した場合も、終了後最低10秒間の計測を行い、
取得が遅い環境では5回の観測が終わるまで延長します。

継続高負荷では、実行ごとの専用 WPR セッションで `CPU.verbose` を使い、10秒間の CPU スタック採取を試みます。
既存の WPR セッションを停止せず、DWM の再起動や管理者昇格も自動では行いません。
WPR の権限不足・競合・失敗は採取結果へ明記します。採取に成功した ETL は WPA の
`CPU Usage (Sampled)` で DWM の PID・Thread ID・Stack を絞って解析できます。
採取成功は原因特定を意味せず、スタックの解析は別途必要です。
Windows がプロファイル採取権限を拒否する場合（例: `0xc5585011`）は、
管理者権限の PowerShell から通常の `scripts/test.ps1` を実行する必要があります。
CPU 使用率の監視は通常権限でも動作します。監視自身の回帰テストは
`scripts/test-dwm-monitor.ps1` で実行し、標準入口からも毎回実行します。

結果は `build/dwm-monitor/run-*/summary.json` に保存します。継続高負荷、計測不能、
監視プロセス異常は通常試験の失敗として報告し、互換試験自身の失敗理由も保持します。
個別スクリプトや `CompatibilityTests.exe` の直接実行にはこの外側の監視は付きません。
個別診断にも同じ監視を付ける場合は、次の入口を使用します。

```powershell
. .\scripts\invoke-dwm-monitored-test.ps1
Invoke-DwmMonitoredTest -OutputRoot .\build\dwm-monitor -TestAction {
    & $runner --timeout-seconds 10 $runner --probe-dialog
    if ($LASTEXITCODE -ne 0) { throw "隔離診断に失敗しました: $LASTEXITCODE" }
}
```

`test-compression-order.ps1` は `-CaseNames` に加えて `-Commands`（`a/u/f/m`）と
`-Apis`（`legacy/A/W`）で比較行列を絞れます。複数値は `-Apis legacy,A,W` のように
カンマ区切りで渡せます。既定は従来どおり全件です。DWM の
状態を確認しながら実行する場合は、1 組ずつ新しい workspace で実行します。

書庫末尾の件数取得・メモリ展開プローブは、末尾に `quiet` を指定すると
メモリ展開だけに `-n1` を追加できます。通常モードは従来の表示条件を維持します。
各結果は逐次出力され、時間制限に達した場合も最後に完了した呼び出しを確認できます。
`quiet` の一致結果は表示なし条件の証拠であり、通常表示・進捗通知の検証を代替しません。

```powershell
$probe = (Resolve-Path .\artifacts\Release\CompatibilityTests.exe).Path
$dll = (Resolve-Path .\artifacts\Release\UNLHA32RE.dll).Path
$archive = (Resolve-Path .\sample\lha-master\tests\lha-test16-l1.lzh).Path
& $runner --timeout-seconds 10 $probe --registry '' --archive-tail-probe $dll $archive quiet
```
