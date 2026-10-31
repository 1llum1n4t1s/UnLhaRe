# exp(0) 短絡の反証計画（2026-10-04）

対象は private 旧Q32 depth5 codec のみ。製品、既存の固定ソース、過去の契約・証拠を変更しない。
この計画を実装前に保存する。成功は7-Zip超えや正式採用を意味しない。

## 起こり得る失敗と先行対策

- 数値・エラー差: domain検査を維持し、その直後の d==0 にだけ Ok(Q) を追加する。旧Mathと全LUT/count、固定境界、決定的な正値群、負値・上限超過を直接比較する。hashだけの比較をしない。
- 誤った候補配線: old codec は旧Math/旧pool、new codec は新Math/数値本体が旧poolと同一の専用copyを参照する。modelは同じ凍結bodyを用い、同名importのaliasだけで配線する。
- 圧縮仕様の変化: 同一binaryのABBA一周、encode/decode各4回のみ。全plain4回、firstAと後続全frame3回、Proof全14field（CDFはbits）、stats直接比較を必須にする。478750Bの固定frame、既存の483599B上限を維持する。
- 誤った速度採用: 事前にold/newそれぞれ2回の平均を比較し、encode/decode双方短縮を次段候補条件とする。一周・warmupなしの診断であり、正式gate（median <574.5624ms、CPU<=15%、holdoutとカテゴリ、4native環境/製品API）は未検証のまま。片方でも遅ければ候補は非採用、同条件再試行はしない。
- timeout/出力増大: compile60秒、各診断CLI90秒。stdout64KiB/stderr16KiB上限、ProcessStartInfoでshell不使用、超過時は所有childのみkillし終了を待つ。失敗報告も保存する。CLIはcompare-math1回、abba1回だけ（必要な修理は別途根拠を記録）。
- ディスク増大: 専用build rootは新規・非reparseのみ。開始/終了でdisk-budget.ps1、予算8MiB、空き5GiB+8MiB。EXE1MiB、report256KiB、source300KiB。Cargo/PDB/asm/rawtrace/frame/plain/input copyを生成しない。失敗証拠も上限内。削除はこの作業では行わない。
- 凍結参照変化: 成功済みstage reportの174 identitiesをbefore/after/liveでSHA256/bytes/mtime_utc照合、basis report SHAを固定。追加sourceとtemplate、compiler/runtime/inputも識別する。検証失敗はpassへ上書きしない。
- 複数起動/既存上書き: 出力先が既存なら拒否。候補EXE所有processが存在すれば起動しない。終了時所有process0を確認、環境全CPU無負荷とは主張しない。

## 固定参照

- basis: build/khc-quaternary-cts-stage-profile-cfg-20261003/report.json SHA256 1A5D148CC5E7D2B46F7C30BB646FB8DDB8FECE72E9FDA37C2E8350DC184E3528。
- input: build/khc-current-source-native-solid-20260923-group/all.group、2811006B、SHA256 18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。
- rustc 1.98.1 x86_64-pc-windows-msvc SHA256 CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。
- pwsh 7.6.5 SHA256 362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。
- flags: edition2024、frame_audit、primitive_audit、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、/DEBUG:NONE。

## 担当・観点台帳

- Performance/Hardening: 読み取り専用analyst predict_cost_analysisが旧CTS/pool/Mathを調査。ゼロ短絡は各方向最低3825340回の一般exp計算を避け得るが時間効果は未測定。10倍改善の根拠ではない。
- Modernizer: 既存固定rustc、依存追加なし。更新は今回の数値問題と無関係、現状維持。
- Normalizer: 旧型・エラー順と単一Math初期化を維持、方式混在の追加は private A/B診断だけ。
- Cleaner: 既存参照は保持。専用pool copyは候補型の分離に必要、数値差分ゼロのallowlist検証を行う。
- Tester: 新規unit testは作らず、先行計画に基づくstandalone E2E/直接境界比較。既存stage83件passは基礎証拠で、今回の新規経路を代替しない。
- Async: runner所有process/streamをfinallyで解放、timeout後も終了確認する。codecは同期、並列化しない。
- Startup/Intel: private診断のため利用者起動/配信は非該当。外部の現在仕様に未解決の照会なし。

親はrunner/結果、workerは新rootのRust6fileのみ所有。既存ファイルは読み取りのみ。独立した読み取り専用検証後に実行する。
