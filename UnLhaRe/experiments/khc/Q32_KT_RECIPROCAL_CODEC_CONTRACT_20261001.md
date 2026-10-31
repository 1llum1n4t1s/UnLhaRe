# KT reciprocalの実codec統合条件

Model proofは62checks/59CLI、旧独立BigInteger Model oracle11267records・7histories・4ビルド全byte一致、KT旧65536recordsのoverflow/cap順も通常/portableで一致。Modelごとにtable1個・実storage524296B、Node16B/Prediction544B、凍結helperから診断cfgのみ変更。通常codecではaudit cfgを一切付けない。

失敗条件を実行前に固定する: compiler/source/helper/Model proofの長さSHAとhold/after変化、Model proof未成功又は未実行、codecの凍結native32からのbyte差分、120秒期限、旧codecとのframe全byte/EncodeStats不一致、restore不一致、破損frameの公開、既存outputの変更、所有tmp/reparse残存。native32 E2E verifierをcloneし、共有依存・旧codec・固定groupを保持。新root `build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001`、既存root拒否・自動retryなし。

通常x64/forcedportableのopt3でempty/single/all_bytes/repeated/periodic/seeded_random/fixedを評価。固定group2811006B、従来frame483469Bと全byte一致、双方cross-decodeとnative反復。magic/headerCRC/payloadCRC/trailing/truncatedを両モードで拒否し、encode/decodeのno-clobberを確認する。これはFocused E2Eであり、過去87項目の全再監査ではない。Model fixtureで到達しない大分母fallbackは実固定groupにも含まれる（凍結distribution証拠）。

初期化とtableメモリを全CLIに含める。size gate483599B以下・encode strict574.5624ms未満は変更しない。速度は別の固定quiet-host測定で判定、correctnessのみで速度採用しない。製品統合・holdout・Windows/macOS x64/ARM64 native・decode/peak memory・総合7-Zip超えは未達として保持する。unit/Git/外部write/x86/CPU設定/閾値緩和なし。
