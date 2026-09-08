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
正常終了した試験用ディレクトリーだけを自動削除します。失敗の再試行や期待値の緩和は行いません。

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
試験の区切りで DWM の CPU・メモリが落ち着くか確認し、継続負荷が残る場合は
計測結果を保存してから、許可された作業セッションの DWM 再起動を行います。
権限が不足する場合は、管理者による操作が必要です。

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
