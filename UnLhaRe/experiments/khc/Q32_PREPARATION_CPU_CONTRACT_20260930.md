# Q32比較の証拠走査負荷 — 限定診断の先行契約

対象はQ32性能入口が最初の子起動前に65%で拒否した記録。比較report SHA `354840497707DBD40D47387D0A20A840EAB24513FCB468D4CC5B77BA733363EC`、compare SHA `2D5C7D57A4940861D01AD1558D8A3E9A27217B80FF40D716BDB356506C29DD4B` は凍結。仮説は734 pinsの祖先検査/readlock/hash走査が自己CPU負荷を発生させた可能性。反証条件は同じpin走査中の全CPU busyの大半が診断自身のCPUではなく残差であること。過去65%の発生主体や不透明CIM windowの帰属を現在の診断から断定しない。

通常比較・quiet guard・15%・固定size/time/group/native設定は変更せず、圧縮/展開/7z childを一切起動しない。最大3逐次試行・各120秒の限定診断だけ実行する。各試行は1秒idle window→既存734 provenanceを記録順に祖先検査/readlock/hash検査→1秒idle window。走査前後のGetSystemTimesと自己Process.TotalProcessorTimeを同時境界に近接して保存する。CIM値は前後で記録するがbusyを成功条件にせず、診断記録から速度採用をしない。元準備全体の完全replayではなく、pin走査部分のみを再現する限界を明示する。

raw helperは凍結`cpu-window/native-times.cs`を再利用し読込み前lock/hash、1..64 logical CPU、native失敗/後退/zero total/idle>total/1秒未満/非finiteを拒否する。自己CPU tickは100ns単位、raw total/busyとの差分・割合を明示し、境界の僅少差のため残差が負の場合は黙ってclampせず記録上invalidにする。idle/scan/idleは各独立開始終了snapshot、self CPU、UTC/Stopwatch境界を保持し、割合だけでなく整数rawを保存する。raw差分は別担当がBigInteger再計算する。

source所有は新`causal-bayes-q32/diagnose-preparation.ps1`をworker一人、契約/開発文書は親。生成rootは新`build/khc-bwt-causal-bayes-q32-20260930/preparation-cpu/`、reportのみCreateNew/既存root拒否/全祖先nonreparse。既存734 filesを変更/削除しない。自己source/contract/helper/元report/比較sourceもreadlockとbefore/after hash。各trialで開いたlockをfinally解放、失敗reportもCreateNew、全3trialでpins不一致/型不正/読込不能ならfailed。現在OS/CPU/PS/絶対sourcepath/hash/mtime/CWDを記録する。独立担当はsource範囲と実reportを読み取り監査、実装担当はParserだけで実診断は親が起動する。

新unit/Git/version/deps/API/製品/公開/他process停止/priority/affinity/power/cache/UnLha32Re/registry操作なし。source/契約/reportは次の判断に必要な証拠として保持。診断成立は総合7-Zip超過や固定時間gate通過ではない。結果が仮説を支持しなければguardを修正しない。同条件のblind比較再起動も行わない。
