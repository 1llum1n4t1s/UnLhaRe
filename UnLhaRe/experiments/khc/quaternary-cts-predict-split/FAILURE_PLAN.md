# CTS/pool分離診断の先行失敗計画（2026-10-04）

exp-zero候補は両方向短縮gate不成立。数値不変の旧Q32 depth5に戻し、局所計算の時間内訳だけを測る。
製品、固定証拠、既存ソースは変更しない。正式速度/CPU/7-Zip超えは主張しない。

## 失敗条件と対策

- 数値body差: modelは凍結depth/modelのcopy。context/guard/CTS/pool/observe/副作用順を不変とし、predictの2call前後に観測だけを追加。candidate codecは旧pool/旧Mathで配線し、モデルcopyへのpathのみ変更する。数値差分は許可しない。
- 時計歪み/二重加算: component×prefixの8層ごと1始まりordinal%256==128だけsample、各direction独立。以前のstageとsample位相を揃える。CTS+pool spanを親、CTS/poolを子として同じsampleだけ測る。残差は親から子をcheckedで引き、負値は失敗。親はcontext取得後からpool完了までで、predict全体やpayload時間とは呼ばない。平均外挿/overhead補正/全時間への割合転用なし。prefix1 sample0は時間不明。実時計の試行数は未追跡、保存されたnsだけtransactionalでありclock readをrollback可能と主張しない。
- counters/scopes不整合: totals/sample/started/completedとnsをchecked更新、拒否・overflowは診断を失敗させる。Stateは数値model外のthread local、enable/resetは各codec call前、finishはsample件数・未完了scope0・総branch数3825340を照合。8層期待 totals=[121,415562,13461,2296628,1,71469,7502,1020596]、samples=[0,1623,53,8971,0,279,29,3987]。
- E2E欠落: baseline encode1（無観測）→profile encode1→profile decode1のみ。全frame478750B直接比較、全plain2811006B直接比較、Proof14×2（CDF bits）、stats3組一致。input read1、frameは最大2/957500Bでdisk copyなし。新unit testを書かず、この実経路のE2Eと計画済みcounter直接診断を用いる。
- 失敗拒否の不明確さ: 先にprofiler契約を単独standaloneで確認（mode disabled、invalid component/prefix、sample境界127/128/383/384/385、残差負値・sum overflow、counter overflow、未完了scope拒否）。副作用はprofilerに限定し、数値modelを変更しない。成功/期待Err件数を出す。
- timeout/容量: compile60秒、契約CLI60秒、profile CLI90秒、各1回。stdout64KiB/stderr16KiB bounded読取、所有childのみkill/終了待ち。新出力8MiB、EXE1MiB/report256KiB/source300KiB、空き5GiB+8MiB、disk-budget開始/終了。Cargo/PDB/rawtrace/inputs/frame/plaincopyなし。既存outputは拒否、削除は行わない。
- 凍結参照差: exp-zero report SHA42BD5E85FAEB54853BCA75D4ACD90140FB85927F2DADB93F4AAE0EF68CEE4F19と189 identitiesを継承。新source/EXEをbefore/after/live照合。input/compiler/runtimeは同じ固定identity。グラフ閉包を全て証跡へ接続、allowlist確認後に独立読取検証を挟む。

親所有: verify.ps1/結果。worker所有: codec.rs,optimized_codec.rs,model.rs,probe.rsの4Rustfile。親から同時編集しない。scopeはprivate診断、Git/外部/リリース/削除禁止。6基本観点の台帳はexp-zero計画を継承し、Performance/Testerは今回観測のcounterとE2Eへ更新。Modernizer/Normalizer/Cleanerは現状維持、Hardening/Asyncは診断runnerへ限定、Startup/Intelは非該当。
