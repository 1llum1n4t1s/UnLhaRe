# SIMD posterior候補の正式比較結果

本goal turnはPROGRESS。新SIMD候補を固定したcomparerを検証して一度だけ実行し、CPU静穏条件違反でterminalと確認した。その後、静的layoutの証拠からcompact商候補を実装し数値E2Eへ進んだ。同一候補の再試行/勝利主張は行わない。

- comparer `causal-simd-quotient/compare.ps1` SHA256 `D31CF484DB4078D733DB70CD7DF9271241B079366144C1C54BCCF078ED280165`。旧Q15 comparerの全文から11明示置換、runner全文対応、8helper AST本文不変、37 support pins現在SHA一致を起動前に確認。既存96MiB prospective performance枠、whole parent128MiB枠。固定483599B / encode median<574.5624ms / warmup1+9 / circular / CPU15% / full CLI wall / native optsを維持した。
- attempt `build/khc-causal-simd-quotient-20261002-warning-fix/performance-attempt.json` は1400B、SHA256 `3CA780EC6306BBBC439FEDE28FC2F7D7863DFC3FCBDB1AB0ACB0C114B28F8882`。
- UTC2026-10-01T18:14:03.5621359Z〜18:14:08.0927679Z、PowerShell7.6.5、CWD `C:\Users\IMT\dev\UnLhaRe`。preflight総CPU0% / 9% / 20%で、3回目が上限15%違反。`Host CPU busy; no ordinary performance adoption allowed.`、wrapper exit1、セッションなし。
- candidate/control/7zaのCLI0件、warmup0件、measured0件。performance root/reportは未作成。速度中央値/対比/採用判断は成立しない。静穏が現在も違反する、あるいは新kernelが速い/遅いとは、この終了時観測から推論しない。
- 新旧全歴史proof閉包の実行前再hashはcomparer内部でpreflightより後のため、今回未実行。現在37 support pinsと8ASTの事前確認を、数千件の閉包実行済みと混同しない。既存wide/narrow guardの厳密例外2件はsourceで維持しているが、今回の実行適用数は0。
- 終了確認時のfull親20218379B(既存proof/EXE/frame/restore含む)、関連process0。新しいcompiler/EXE/Cargo target/raw traceはこの正式比較では生成していない。C空きは外部状態の観測値であり、今回の回収成果とはしない。

新compact helperの成果と次の安全な実装経路は `COMPACT_SIMD_RESULT_20261002.md`。goal全体は未達、activeを維持する。元integer/Q15/SIMDのterminal試行を再開/自動再試行しない。
