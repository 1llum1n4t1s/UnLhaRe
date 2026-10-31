# Light suffixモデルのcompact path: 実装前失敗計画

前turnはheavy Nodeの32bit保存と55項目のE2Eが成功しPROGRESS。正式速度比較はnative予備decode直後のCPU28%でterminal、正式測定0件。これを再実行せず、別の計算量削減候補を数値/状態CLIで検証する。固定ゲート、観測器、初期化位置、pendingな再評価方針は変更しない。

仮説: light Predictionの17個のusize indexesを廃止し、16bit historyのbit reversalから末端index=65535+reverse(history)を求め、parent=(index-1)/2で走査する。predictは末端から32観測以上の最深nodeを選び、updateは全17nodeを元と同じleaf→root順に学習する。Nodeはzero/oneの代わりにtotal/oneを同じ8Bで保存し、zero=total-oneをKTへ渡す。浮動小数・確率・選択閾値・履歴・class・cap・stale処理は変更しない。

安全性: 合法な初期状態total=one=0。各成功更新でtotalを1増加、oneはbit=1のときだけ1増加するので0≤one≤total≤class observations≤562036803を保持する。zeroの差分は旧式のzeroカウントと一致する。countはchecked算術を維持し、ゼロの計算もchecked subtraction。class cap拒否は元と同じくnode更新前。捏造したprivate countsやindexesへ旧式と同じエラー順まで保証しない。

反証/失敗条件を実装前に固定する:

1. mapping誤り: 全65536 history×17depth（1114112値）を旧bitごとのheap recurrence、閉形式、親走査の三者で直接比較。depth17/usize::MAXは拒否し、root/leaf/最大indexを含める。raw列は保存しない。
2. expert/学習差: 凍結light SHA F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32のcfg追跡とaudit append版、新sourceを同一CLIへ取り込む。131072イベントの固定seed・7class・連続/交互履歴を通して、Q15予測、Q32予測と実selected depth、全17nodeのindex/zero/one/total、履歴・観測を逐次比較する。cfgのみの追跡で選択結果を記録し、Prediction自体へ診断fieldを加えない。いずれか1値でも差があれば棄却。
3. stale/拒否の差: 二重update、class mismatch、invalid predict class、注入したclass capの拒否と拒否後の継続/状態を比較する。cap注入は境界拒否の検証で、到達可能状態の生成や全cap位置総当たりとは扱わない。
4. cfgによる差: standalone CLIをopt2/opt3×overflow-check有無の4条件で実行し全summary同一を要求。旧sourceの通常部分は不変、audit appendとsource全置換対応を保存・照合。新audit exportsもcfgのみに限定。
5. layout/使用: Node8B不変、新Predictionからindexesが実際に消え、旧より小さいことをruntime sizeで確認。snapshotの削減を総RSS/速度改善へ読み替えない。full scheduler/codecの組込み・wire一致・正式速度評価はこの段階では未検証と明示する。
6. 容量と実行境界: build/khc-light-compact-path-20261002をfreshに一度、予算4MiB/空き5GiB+予算の前後guard。4小EXEとbounded JSONのみ、/DEBUG:NONE、no Cargo/cache/PDB/rawdump。全source/compiler/runtime/CWD/argv/SHAと件数を残す。compiler/CLI timeout120秒、期待外stderr/exitはfailed report、同sourceの自動再試行・既存proof上書きなし。
7. 目標の縮小禁止: 483599B以下、encode中央値厳密574.5624ms未満、CPU15%以下、warmup1+測定9などの固定ゲートを維持。holdout/カテゴリ、同境界decode、四native決定性、製品/API組込みと安全性が揃うまで7-Zip総合超え/goal達成を主張しない。前のwarmup単発値を正式評価へ読み替えない。

編集担当は親のみ。製品コード・x86・version・Git・公開・共有cache・他process/CPU設定は変更しない。用途を終えた一時物だけ安全条件を確認して清掃する。
