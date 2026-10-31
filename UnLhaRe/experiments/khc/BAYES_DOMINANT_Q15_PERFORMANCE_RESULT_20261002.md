# Q15優勢shortcut正式比較: preflight CPU16%、CLI未実行

試行はUTC2026-10-01T17:06:01.6734272Z〜17:06:06.4157054Z、terminal failed。5回予定のpreflightの0/1/2回目は8/6/16%、固定15%違反で終了した。候補/control/7za CLIは一度も実行していない。warmup/計測samples0、中央値/対比/速度採用なし。性能上のNO-GOともGOとも判定できない。前integer試行と本試行は別のsource/binaryだが、どちらも失敗を再開/自動再試行していない。

正本はbuild/khc-bayes-dominant-q15-20261002-codec/performance-attempt.json、1407B、SHA DDEFF70E17EB952E1558FEA228DB7194E1F3095EFCA6C3CC9D3B98FA8587D77D。work_created=false/report_exists=falseなのでperformance/report.jsonは不存在。wrapperのattemptはあるため同じ入口は再実行を拒否する。

## 実行前確認と未実行検査の区別

- comparer SHA3E5E745572D8F6AEEB5026E481AF329D8FD00ED000F85BA673F143EC8E81F232、更新UTC2026-10-01T17:04:40.1050727Z。bundled pwsh7.6.5、CWD C:\Users\IMT\dev\UnLhaRe\UnLhaRe。候補EXE A98326FBF88608DACE22D44DF934DF5EC3062AB684E934F644013024E69B0FBE。
- 元integer comparerから10明示置換、source全文一致、8helper AST本文一致、21 support pins、fresh root/attempt、128MiB budgetは開始前の読み取りコマンドで確認済み。performance-correspondence.jsonとperformance-support-pins.jsonに再現条件を保持した。
- comparer自身ではpreflightが旧proof閉包の全hash照合より先にある。したがって本試行で2174件の閉包/2393 provenanceを再検証したという主張はしない。前回の証拠と本試行を区別する。
- CPU15%、warmup1+9/circular/CLI境界/完全483599B/574.5624ms/optsは維持し、CPU観測から自分に都合よくsampleを除外/追加しない。優先度/affinity/power/他process停止は行っていない。
- 生成物はbounded attempt1407Bのみ、performance rootは作られず、EXE/Cargo cache/raw/ETLは生成なし。

## 次の行動

静穏状態が必要な正式速度評価を無条件にリトライせず、論理回数監査へ進んだ。OPERATION_COUNTS_RESULT_20261002.mdの実際の有限codec結果が次の改善箇所を選ぶ証拠となる。速度勝利/holdout/四native/製品統合は未達、goal active。CPUが静穏になったことだけを新しい同候補自動再試行の根拠にしない。

