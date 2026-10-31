# Hamilton必要分だけの選択：先行失敗計画

前回はCTS内部3区間のsample時間和でKernel84～85%を確認。今回はkt/normalize_q2の順位選択だけを試す。数値同値だけでは速度採用しない。7-Zip固定総合目標は変えない。

## 先に列挙する失敗

- left0/1/2/3、prefix1～4、最大余りtieで旧新vectorが異なる。left1はchild昇順strict greaterで選択する。
- invalid prefix、raw CAP、weight/vector、Hamilton sum/increment、mixture overflow等のguard・error字面・順が変わる。
- quotient/remainder、元KT除算、update_kernel、Snapshot構造・DerefMut/認証・commitが変わる。過去不採用equalmass候補を再混入する。
- fullframe478750 bytes、plain2811006 bytes、Proof14 fields/CDF bits、stats22 fields、拒否前後全stateが不一致。
- 固定ABBA old/new/new/old1cycle（encode/decode各4calls）の中央値でどちらかが短縮しない。短縮しなくても再試行せず不採用記録を残す。
- pins SHA256/bytes/mtime_utc不一致、既存output上書き、source300KiB/EXE1MiB/report256KiB/root8MiB、空き5GiB＋8MiBを満たさない。

## 変更と検証

新source `quaternary-cts-hamilton-select/`、output `build/khc-quaternary-cts-hamilton-select-20261004/` のみ。kt-equalのrunner/ABBA/probeを機械templateとして使うがCTSは元depthから複製する。ktとnormalize_q2それぞれでleft0は順位不要、left1は最小child tieのargmax、left>=2は元sort。checked increment以降と前置guardは凍結。explicit逆復元allowlistを実行前照合。

standalone直接比較CLIは元kt-equalの17320 KTケース（prefix毎に原値／error直接比較）を保ち、left全境界・tieを含むmixture正常/異常・境界・決定的系列も直接比較する。単なるdigestだけで一致を主張しない。旧/新model拒否tuple14/16/1、CTS正常/修復後受理・stale/derived/未使用tail拒否の全state比較を確認。ユニットテストは追加しない。

compile1回60s、直接契約CLI1回60s、ABBA1CLI120s上限。stdout64KiB/stderr16KiB、所有processだけ終了処理、rawtrace/frame/plain/input/PDB/asm/Cargoは生成しない。新JSON容量を事前計算。basisは直前inner report SHA59C4C8B73DF3275303D52629C3862CD1F83D260AF60EC9E4D8A024AA95571562、215identities継承＋そのreport/EXE＋新sourceを前後/live照合。

所有: workerは新root全ファイル、親は上位計画・結果・native実行。編集停止/返却後に独立読み取り確認。通常worker Sol/medium、独立analyst Sol/medium。既存変更を保護しGit/delete/外部操作なし。

観点台帳: Performance=Kernel選択候補、Hardening=数値/拒否順とbounded runner、Tester=直接比較/全E2E/ABBA、Normalizer=凍結モデルと候補境界維持、Modernizer=依存更新不要、Cleaner=古い証拠を削らず新root限定、Async=所有child/pipes寿命、Startup/Intel=今回非該当。正式速度574.5624ms/CPU15%以下、独立holdout/カテゴリ/4環境/製品APIはこの局所ABBAでは証明できない。
