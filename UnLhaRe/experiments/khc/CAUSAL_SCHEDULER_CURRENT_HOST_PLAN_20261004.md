# 未測定schedulerの新しい静穏条件による単回比較

前turnは費用screenの実行/棄却と保存証拠の独立確認がありprogress。総合GOAL active。2026-10-04T07:13:36–41Zの凍結quiet observer新観測0/4/0/1/1%が15%以下。これは10月1日のquiet失敗とは外部条件が違う新しい試行であり、旧失敗rootを再起動/上書きしない。測定中の静穏は保証せず元observerを全入口/終端で維持。一度のみ、閾値・優先度・affinity・電源変更なし。

対象は通常causal scheduling EXE SHA0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA。既存correctness proof50checks/63CLI/83pinsとframe483496Bを同じDFS/全support pinsで再照合する。元compare.ps1 SHA785727BDEA01C90788707E352B215048D9934DA1848FFC5982BFBD4402EC69C2は変更禁止。新wrapperが全文を読み、唯一のexpected-work文字列をbuild/khc-causal-scheduler-current-host-20261004へ置換、PSScriptRootだけ凍結source directory変数へ再基点化。8measurement/verification functionsのAST全文を置換前後で照合して一致を要求。warm1+9、循環順、全CLI境界、静穏15%、encode574.5624ms/size483599B、制約と集計式は元通り。

先行失敗条件：wrapper/source/tool/input/report pin差、再基点またはwork置換件数不一致、AST差、既存root/reparse、CPU違反、CLI失敗/timeout、完全frame差、復元/metadata差、round不足、provenance変化、容量超過。safe root作成後は元失敗reportを保持し再試行しない。生成前後disk-budget実行、既存proof/source/corpus/EXEのコピー/再buildなし。

容量上限は128MiB（既定256MiBより小さい）。概算worst：入力snapshot6MiB＋30書庫*3MiB=90MiB＋候補/control復元4*3MiB＋native復元2*3MiB=18MiB＋report8MiB=122MiB。固定成功書庫は各約0.48MiBなので通常保持は40MiB未満を想定。これは事前/事後検査で、hard write quotaではない。Cargo/PDB/rawtrace/新巨大corpusなし。用途終了の生成物清掃はglobalごみ箱手順による別判定が必要、証拠は保持。

scope六観点は親担当：Modernizer依存不変、Normalizer凍結AST/observer再利用、Performance未測定候補の正式比較、Hardening失敗/identity/quiet境界維持、Tester全proof/復元/9round検証、Cleaner新build/cacheなし。Asyncはchild終了/stdio drain/locks/finally、Intel外部現在値不要、Startup製品不変で非該当。製品dirty/API/version/x86/Git/外部writeなし。nativeの11出力とgroupの1出力decode境界が異なるのでdecodeは採用対象外、4native/holdout/完成書庫/製品を含む総合GOAL達成にはならない。
