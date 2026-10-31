# 新しい静穏条件のscheduler比較：CLI起動前で失敗

2026-10-04T07:13:36–41Zの凍結observer ProbeOnlyは0/4/0/1/1%で通過。別rootの正式比較wrapperを一度実行したが、07:15:37.0145359Zの入口preflightは17%で15%上限を超過しexit1。時間窓が違うため、先行観測の通過を正式実行中へ流用しない。

元compare.ps1 SHA785727BDEA01C90788707E352B215048D9934DA1848FFC5982BFBD4402EC69C2をreadlock保持し、work文字列1置換とPSScriptRoot再基点化の後、8functions AST全文一致を確認。算法/observer/warm1+9/循環順/固定gateは変更0。候補/control/7zaの起動0、warmup0、測定0。総合性能判断に使える速度証拠は得られなかった。

未使用root C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-causal-scheduler-current-host-20261004 は作成前に失敗、生成量0B。前guard free52974854144B、後guard free52974460928B、実験予算128MiB/最低空き5GiB。元rootと10月1日の失敗reportは保持。閾値緩和、同条件自動retry、他process停止、priority/affinity/power変更なし。観測17%の原因processは未特定。

前turnは費用候補の実装/実行/棄却、本turnは新条件による正式入口の実失敗が次の行動を制限したprogress。CPU待ちだけをタスク全体の停止/blockedへ読み替えない。独立工程では保存無料分布でなく因果的なhard-cut context treeによる演算削減の成立をコードから反証する。これは未実装の別モデル仮説で、サイズ・速度成功やportable出力は未証明。GOAL active/未達。
