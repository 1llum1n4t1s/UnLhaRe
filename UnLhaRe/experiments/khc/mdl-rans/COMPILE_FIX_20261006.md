# 初回compileを保持した借用エラー是正

2026-10-06。screen-a/sessiondf3f31 exit1は実行前Rust E0503。candidateのgate(&mut s, base+s.journal_capacity+s.journal_transient)が第一引数の借用と衝突した。計算をlocal journal_live_boundへ先に保存してgateへ渡すだけのv2を作る。CDF、rANS、上限、形式、評価条件の変更0。元candidate/compare/runner/source/reportを変更せず保持し、再現のsource SHAを消さない。

初回report11841B SHA6B224926E9C41159F030C230A42DD07FD518A91096DEA5F13F8C8EB9943EC264。成功したEXEやnative結果はまだない。candidate_block_v2.rs、compare_v2.rs、compare_v2.ps1で別のscreen-b先へ同compiler/同fixed8MiB/64MiB/suite条件で進む。逆順の参照先も成功したscreen-bだけにする。旧実験の性能を流用しない。

read-only analyst mdl_rans_contract_audit（role既定gpt-6.1-sol/medium）は独立静的反証で式・byte順・終端・error-state commit・12MiB/6MiB課金・LZ分離の成立欠陥なし、実E2Eだけ未検証と返した。静的結果を実行成功とはしない。親が次の有限E2Eを実行する。
