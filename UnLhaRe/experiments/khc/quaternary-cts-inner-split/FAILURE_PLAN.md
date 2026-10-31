# CTS内部predict分離診断の先行失敗計画（2026-10-04）

既存CTS/pool診断を継承し、CTS内部predictのguard/gather、Kernel、snapshot構築/sealだけを分離する。observeは未測定。親計画は `../QUATERNARY_CTS_INNER_PLAN_20261004.md`。
製品、固定証拠、既存ソースは変更しない。正式速度/CPU/7-Zip超えは主張しない。

## 失敗条件と対策

- 数値body差: codec二つは既存predict-splitの完全コピー。modelはScopeのsample flagを渡す診断呼び出しだけを変更。CTSはdepth/integer_cts全体を完全コピーし、元predict/observeを変更せずpredict_profiledを追加。明示allowlistの診断行を除いた追加methodが元predictに完全一致することをrunnerで確認。Snapshot/Kernel/Nodeの構造・derive・DerefMut、guardとcommit順、modified-visible exact-current fallbackを変更しない。
- sample対応の侵入: observeとのticket保持はSnapshot構造を変える侵入になるためpredict-onlyへ縮小。既存Scopeのticket有無をCTSに渡し、同じsampleの3分割値をScopeに返す。非sampleはpredict_profiledの時計なし・元predictと同じ数値body、observe内fallbackは元predictで時計取得なし。observe normal/fallback件数は未計測。
- 時計歪み/二重加算: component×prefixの8層ごと1始まりordinal%256==128だけsample、各direction独立。以前のstageとsample位相を揃える。CTS+pool spanを親、CTS/poolを子として同じsampleだけ測る。残差は親から子をcheckedで引き、負値は失敗。親はcontext取得後からpool完了までで、predict全体やpayload時間とは呼ばない。平均外挿/overhead補正/全時間への割合転用なし。prefix1 sample0は時間不明。実時計の試行数は未追跡、保存されたnsだけtransactionalでありclock readをrollback可能と主張しない。
- counters/scopes不整合: totals/sample/started/completedとnsをchecked更新、拒否・overflowは診断を失敗させる。Stateは数値model外のthread local、enable/resetは各codec call前、finishはsample件数・未完了scope0・総branch数3825340を照合。8層期待 totals=[121,415562,13461,2296628,1,71469,7502,1020596]、samples=[0,1623,53,8971,0,279,29,3987]。
- E2E欠落: baseline encode1（無観測）→profile encode1→profile decode1のみ。全frame478750B直接比較、全plain2811006B直接比較、Proof14×2（CDF bits）、stats3組一致。input read1、frameは最大2/957500Bでdisk copyなし。新unit testを書かず、この実経路のE2Eと計画済みcounter直接診断を用いる。
- 失敗拒否の不明確さ: selfcheck-inner単独CLI1回で実時計なしのprofiler9群/期待Err23を確認。disabled、invalid component/prefix、sample境界、親子・内側残差負値、sum overflow、全12counter/ns overflow、未完了scope拒否で全State比較。旧/新model rejection tupleは双方14/16/1。旧modelは凍結depth/modelで元predict、新modelは追加predict_profiled（無観測）。独立CTS契約はfrozen depth CTSと追加CTSで未改変受理、foreign-certifiedのvisibleを現在値へDerefMutで全置換後受理、stale/derived/unused Kernel tail拒否と全Cts Eq状態保持を照合（双方合計受理4/拒否6）。tupleだけでmodified-visible受理を主張しない。
- 内部分解: gather/kernel/seal合計とCTS親の差をinner_residualとしchecked計算、外側親CTS+poolと混ぜて二重加算しない。保存量は実size_of(Node/Kernel/RawSnapshot/sealed Snapshot/Cts/Stratum/State/Scope)をJSONへ記録。4境界のclockと配置が極小spanを歪めるため速度改善や外挿を主張しない。clock試行数はnull。
- timeout/容量: compile60秒、契約CLI60秒、profile CLI90秒、各1回。stdout64KiB/stderr16KiB bounded読取、所有childのみkill/終了待ち。新出力8MiB、EXE1MiB/report256KiB/source300KiB、空き5GiB+8MiB、disk-budget開始/終了。Cargo/PDB/rawtrace/inputs/frame/plaincopyなし。既存outputは拒否、削除は行わない。
- 凍結参照差: kt-equal report SHA3DFC56A76C7186B79BFFF56DD8A4D3064510D6A8C7BED49D4ABF118884C47404と206 identitiesを継承。新source7個（source合計300KiB上限）/EXEをbefore/after/live照合。input/compiler/runtimeは同じ固定identity。グラフ閉包を全て証跡へ接続、allowlist確認後に独立読取検証を挟む。

worker所有: 新rootのcodec.rs,optimized_codec.rs,model.rs,integer_cts.rs,probe.rs,verify.ps1,FAILURE_PLAN.md（7files）。親所有: 上位計画と結果、native実行。実装時はcompile/実行をせずreadonly preflightまで。scopeはprivate診断、Git/外部/リリース/削除禁止。新unit testなし。
