# Compact full候補の正式比較結果

CPU preflightで終了し、速度評価は未実施。この試行はterminalとして保存し、自動再試行しない。

- 契約: `COMPACT_CODEC_PERFORMANCE_CONTRACT_20261002.md`、SHA256 `2EE54292F7BC636A57574E69A8231D4189F65BB3D7A0B4821E8A61374CB9B01F`。
- comparer: `causal-compact-simd/compare.ps1`、SHA256 `1BE81D1A34C8CDACDA75550C68F49ED3A2CA86AF3E1DFA8D256F8D0C5BF53C80`。元comparerから10件の明示対応、8計測helperのAST不変、54 support pinを事前確認した。
- attempt: `../../build/khc-causal-compact-simd-20261002/performance-attempt.json`、963B、SHA256 `FD58F78D8896E962C7A1CCA0C061BE19B134EA054C82558CD892808EC567AD51`。
- UTC 2026-10-01T19:04:04.4172178Z〜19:04:06.7501935Z。最初のpreflight観測は26%、許容15%を超過。終了理由は `Host CPU busy; no ordinary performance adoption allowed.`。

codec/control/native実行0件、warmup・測定サンプル0件。performance出力ディレクトリとreportは作られていない。history proof closureの実行はpreflightより後なので未実施。54 pinとASTの事前確認を、歴史閉包全体の再検証済みとは扱わない。

上限483599B、encode中央値厳密574.5624ms未満、warmup1＋測定9、総CPU15%以下、CLI前後の観測、single-thread、実行順と時間境界は変更していない。後の低CPU診断によってこの失敗を合格へ読み替えない。

観測器の初期化・証拠確認を測定前に分離して同じ候補を新しい枠で再評価する方針はユーザー確認待ち。既存契約・source・attemptは保持し、返答前に同候補を再実行しない。速度勝利・採用・総合7-Zip超えは未証明。
