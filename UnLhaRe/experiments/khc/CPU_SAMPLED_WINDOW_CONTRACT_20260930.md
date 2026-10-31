# P1の元測定経路照合 — 追加1回だけの反証契約

前のCPU_WINDOW契約/report865CE13F...は変更しない。3trialはWaitForExitで待ち、元compareの1ms process/thread/memory pollingを含まなかった。そのため自己負荷の仮説を元の問題経路で完結したとは言えない。次は固定SAISの1回だけ、凍結causal-bayes-sais/compare.ps1（C37651CF01DB86CBC1306E371494AE8210812CE16DE6A4421BFA965309AD751B）のInvoke-Recorded関数をASTから全文そのまま読み込み実行する。暗黙にguardを弱めず、quiet-host.ps1（E66D39AE...）の元Assertを名前だけ変えて呼び、元CIMの合否を先に記録・維持する。計算/式/loopを新実装へ書き替えない。

新cpu-window/diagnose-sampled.ps1と新build/khc-cpu-sampled-window-20260930、開発記録のみ所有。旧関数のbeforeガード後に1秒native静穏windowとduring native/parent CPU開始、afterでduring native/parent CPU終了→元CIMガード→finally1秒native後窓を追加する。元ガード拒否でも終了後窓を保存、codec壁時計の区間内には観測追加なし。追加窓は採用判定には使わず、旧CIM拒否を握りつぶして性能成功とはしない。前guard拒否なら子起動0として保存し再試行しない。child lifetimeのCPUとparent polling CPU/総CPU時間は別境界であり因果推定に使わない。元ガードと新rawの区間は同一ではない。負荷の変動は残るため、旧拒否/new後静穏だけで特定process原因を断言しない。

先に失敗条件: source/helper/candidate/group/proofのhash/長さ変化、関数名/個数/抽出body不一致、reparse/既存root/既存output、API/逆転/zero/idle>total/CPU数>64/1秒未満/非重複不成立、child非zero/timeout/不正frame。readlock前実行や既存proof編集を禁止。source/helper/script/契約/入力/EXEは前後identityを保存、解析関数はローカル凍結所有sourceだけからロード。Native数学/helperは前診断の独立54 FILETIME照合PASS済みsource4838B4D...をそのまま使用。resultはdiagnostic限定、元の固定サイズ/time/nativeopts/thread/採用基準は変更しない。新guard/新unit/Git/version/deps/公開/他process停止/priority/power/affinity/cache/UnLha32Re/registry操作なし。

外側のexec sessionをterminalへ回収、実frame483468B/B4F17...照合、raw/parent CPU/元関数/元guardの呼び出し範囲を独立検算する。1回上限、無意味なblind再起動なし。前診断と今回のfalsepost観測有無からgogo判定を更新し、足りなければ未判定で元guardを維持する。正常性能/9回中央値/7-Zip超過はこの診断では評価しない。
