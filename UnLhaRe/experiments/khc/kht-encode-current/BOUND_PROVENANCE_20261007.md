# 固定11入力のnative encoder予約の出所

2026-10-07。compile/run未実施の準備用資料。native一般入力向けのpreflight APIを完成させたとは主張しない。

既報 `build/khc-row-copy-pruned-rans-native-a-20261007/report.json` SHA58511CE39BA8238B33D28E3B711910204080C9C7CAC84F98A0AB17DE8FD99A5C、completed/live pins true/native_trial_frame_exact/public_baseline_exact/full_trial_frame_exact。native-probe.rs:607..617でglobalはencoder/decoder/baselineの最大で、rowsはprivate codec encoderのlogical_bound。global51654872Bは11入力encoder最大29214581Bを覆う。

独立explorerが原典比較し、親もprobe rows取得を確認：current record.rsとprivate codec.rsの既存encode/record/Stats/gateは同じ並び、差はmodule path/doc/current追加validate_frame。block/mod.rsとprivate baseline_block.rsは14path/空行以外全文同じ。entropy/voter全文同じ、boundはdocだけ相違。usize・MAX定数・memory算定・phase順序も同じ。frame一致だけからメモリ同一性を推定したのではない。

89既報pinsのうち、raw11/encoder graph/compiler/deps等88は現hash一致、src/main.rsだけ差分あり。main.rsはCargo.toml:13..15の別bin unlhare-cliで、lib.rsはmainをmoduleとして読まず、main側がunlhare libraryを呼ぶ方向（main.rs:3）。本driverはlibrary/直接sourceを呼びCLIを使わないため、この1pinはencoder依存graph外として明示除外する。CLIの現挙動・性能・旧全89pins不変を証明したとは主張せず、main.rsを編集・巻戻ししない。

実行controllerがproof SHA、88適用pinsとraw manifest11SHAを再照合してreadlocksを保つことを条件に、native最初のcallにも既報global51654872B＋caller/raw excess/保持frame/driver1MiB/最終frame最大n+40を前払いする。毎callのnative Stats.logical_boundは行別既報値と一致かつglobal以下でなければ失敗。64MiBの上限は維持する。これは同じ入力/source graph/Win64 allocator/toolchainの再現診断だけで、未見・別版・別OS・一般入力へ流用しない。

root-table E2E＋decode gate＋現SHA一致が成立するまでencoder benchmarkは実行しない。現在はroot初compileも未完で、CPUquiet条件不成立。helperの初版fail-closed stubは既存proofを使う条件付き実装へ変更した。新しい上限許可・source予約API・外部依存は導入していない。
