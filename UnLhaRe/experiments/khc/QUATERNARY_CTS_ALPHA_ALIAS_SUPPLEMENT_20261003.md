# Alpha ABBA: 旧独立oracleとcandidate Snapshot比較の接続補足

本補足は未実行の `QUATERNARY_CTS_ALPHA_ABBA_CONTRACT_20261003.md`（9120B、SHAC1D25F68A4A8CEC4CC3A1291E4944121486B8B3DF456B1AE5E9D434B8D9B6DBA）を変更せず、module aliasとidentity件数だけを明確化する。それ以外の数値/入力/エラー/状態/全Proof/全frame/タイマー/ABBA/容量/採否条件は同契約を維持する。

## 発見と修正範囲

workerの途中rootではnew_ctsが凍結baseline、alpha_ctsが候補で、旧codecは前段と文字一致だった。しかし凍結mid snapshot_comparisonは `crate::new_cts` を直接参照するため、その構成ではcandidateのSnapshot拒否を通らずbaselineの再検証になる。kernel oracle比較とdepth0比較だけでこれを代替しない。

- rootのnew_ctsは新candidate integer_cts.rsへ向け、baseline_ctsは凍結depth integer_cts.rsを独立moduleとして参照する。alpha_kernel/reference_cts/old_ctsを改変しない。
- old codecは前段旧codecからuse行の `new_cts as integer_cts` だけを `baseline_cts as integer_cts` へ置換してよい。数値・timer・Proof生成等の本文は同一とし、static guardでこのexact alias以外の差を拒否する。
- optimized codecは `new_cts as integer_cts` でcandidateを参照する。snapshot_comparisonは凍結bodyをそのまま使用し、旧側sealed/q32対新側candidateの392/223/22とdepth4..8拒否probeを実行する。
- 新comparisonはbaseline_ctsとnew_ctsの独立depth0比較、旧reference_cts::update_kernel対alpha_kernel::update_kernelの869全Result比較を実施する。旧側をcandidateへ接続してはならない。

root13、graph17unique/18edges/unique destinations16、新8fileの所有は維持。本補足1件を追加して139basis+新8+主契約1+補足1=149unique identities before/afterに変更する。nonExecuteのbody/compiled graph/validator検証を更新する。workerはFAILURE_PLANへこの接続不備と実行前是正を記録する。compile/候補CLI/Executeはまだ0回で、固定失敗証拠や契約の書換え・検証の省略ではない。
