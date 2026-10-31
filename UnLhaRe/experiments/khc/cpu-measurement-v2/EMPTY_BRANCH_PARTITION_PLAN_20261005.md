# 静穏待ちによるsuite超過への対策

2026-10-05。empty-paidは900秒で失敗。186calls、44frame対が一致、source/input/tool pin不変。fixture0..3は各warmup1＋9×両方式完了、fixture4は部分測定、fixture5/6は未実行。CPUquiet待ち824596ms（総900666ms）で、codec故障ではない。失敗report16464 B SHA256 6C51CCA5CA1B7BA8119A2CD7F6E8A3C6895FA4A8CFAB084F2CBFB4C95157F5B7を改変せず保持する。

同じ全件を再実行せず、runnerへ連続fixture範囲を追加する。対象全7入力、warmup1＋9、交互順序、全frame一致・自己/相互復号、CPUquiet15%、64MiB/60s、suite900sは不変。入力番号・名前・SHA・順序式は元のfiを使い、subsetへ再番号付けしない。今回Paidは4..6を全文測定し、過去の部分fixture4 sampleを結果に混ぜない。0..3の完了分＋新4..6の完了分を区別して参照する。失敗report全体を成功へ変更しない。Lowも必要なら0..3/4..6へ分けて、全入力を必ず含める。

失敗候補：範囲逆転/超過、入力indexとInputs添字のずれ、counter式の旧全件固定、cross/sample不足、fixture選択の恣意化。範囲を生成前にvalidateし、summaryとexpected countsを選択数で計算する。defaultは従来全件、元の入力を削除/差替しない。範囲をreportへ記録する。入力ごとのmin/max/全sampleを保持する。測定集合/採否ゲートは緩めない。

source/exe/runner/corpusはpin、subsetごと未使用dir、最大8MiB/report256KiB、raw/frame disk0、free5GiB。新buildなし。CPUquietの頻度/上限を変えず、他作業プロセスを操作しない。残りを一度実行し、再度静穏待ち超過なら未達として別の独立実装工程を進め、同じ測定を無期限に繰り返さない。
