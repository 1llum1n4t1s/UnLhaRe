# 成功時String遅延化：先行比較E2Eとallocation診断

2026-10-04。親PLAN SHA `4720179C31C8908866EA238CE05AB567902B9F36B2F421E69262D7BCFF1DED78` 全文確認。第一段階は本書と compare.rs のみ。原engine/wire/製品/runnerを変更せず、candidate engine/codec/scope/probe/runnerの接続実装は後段許可まで作らない。compile/native/verifier/Git/外部write/delete/追加委任0。missing future moduleは許容し、非書込構文確認だけを行う。

## 実装前のfaultと判定

- candidate差分が原engineの `.ok_or("Q8 log underflow".into())` と `.ok_or("Q8 price underflow".into())` の2箇所を同文言の `ok_or_else` にする範囲を越えたら実行しない。数値、CAP、更新/commit順、Modelの同原因3箇所は変更しない。未来codecは独立scopeのimport接続だけを許し、モデルやcoder式を変えない。
- 各側encode/decodeの全2811006plain直接比較、typed Proof14 Eq、validate_fixed(5)両側、full stats文字列一致を検査。control/candidate全frame bytes、full stats、全Proof Debug文字列を直接比較する。private Proofは別型なのでcross-type typed Eqを主張しない。Debug全14field比較は固定private診断制約であり、各側typed Eqとの区別をreportに保存する。
- 新wire成功値 frame478856/payloadCRC2323132388/headerCRC735823295/cdf_bits4705461279319865477 は既存証拠。新測定のcontrol/candidate同値は全bytes/全値比較を実行して判定し、ハッシュや既存成功の流用だけで合格にしない。旧原float数値との同値は要求しない。
- 両側の有限fixtureは凍結wire e2e.rsを各codec module配下で再利用する。14正常（空、constant0の1/2/255/256/257/383/384/16639/16640、all256、sparse-high255、LCG4096 seed1831565813、既存text128）、34破損の各厳密reason、4短depth header、CRC既知値、全再encodeframe14を保持。primary全state比較の代用にはしない。必要なprimary有限oracleの再利用許可は後段親判断であり、現在は旧160events/15拒否を今回成功へ転用しない。
- LLVMが既に成功時String構築を除去する可能性を最強反証として扱う。Atomic global allocatorでalloc/alloc_zeroed/reallocのtrait実呼出し数とrequested bytesをencode/decode各区間で記録。各counterと合計はoverflowで拒否。測定区間のnested開始を拒否し、unwindでも終了guardで解除。カウンタ自体はallocation/print/I/Oをしない。
- 入力read、plain/frame/Proof比較、Debug整形、JSON報告、WinAPIは測定区間外。codec run_profile/run_restoreが元から作るstats文字列は両側同じAPI内なので区間に含む。requested bytesはresident RAM/peak/実mallocの物理bytesではない。reallocはnew_size要求を1呼出しとして数え、System内部の実装を二重計上しない。
- allocator instrument自体が最適化/codegenへ影響し得る。結論は計測付きbinaryでのtrait allocation実呼出し差だけ。非計測binaryの物理allocationや正式速度へ一般化しない。両側同数なら利益未実証、増加なら悪化/要調査、減少しても正式速度改善とは言わない。instrumented時間を正式速度へ流用しない。

## 一つの入口と寿命・資源

未来probeはcrate::control_scope/candidate_scope/memory/Resultを供給し compare::run() を呼ぶ。各scopeはwireと同じEncoded/Decoded返却型とcodec::run_profile/run_restore/run_selfcheckを公開する契約。単一global_allocatorは compare.rs に置き、他のallocatorを追加しない。

CLIは `selfcheck-control`、`selfcheck-candidate`、`fixed-compare <fixed-input>` の3childrenだけ（native上限4以内）。selfcheckは既存1JSONをそのまま返し、追加printlnをしない。親runnerが各側14/34/4・正確なreason・WinAPI WS/privateを別recordで検査する。fixed比較は1process/入力read1、control encode1/decode1後にcontrol plainをdrop、candidate encode1/decode1を行う。control/candidateの2frameは全bytes比較のためRAMに同時保持。fixed再encodeは0。I/Oやallocation計測とstdoutを混ぜない。

fixed main dataは input2811006 + frame2×MAX_FRAME1048861 + decodedplain2811006 = 7719734B 上限。Model source boundはbase16MiB（Counts/weights/mathとconstructor一時canonical込み）+primary8190×40+64KiB+tree64KiB+scratch64KiB+prices65536+allocator4MiB = 21561264B。candidate encode phaseはinput+保持controlframe MAX_FRAME+last2×2811007+run capacity1048576×12+range payload1048576+candidateframe MAX_FRAME+Model bound = 45723494B。candidate inverseはinput+2×MAX_FRAME+14×2811007+scratch65536+allocator4MiB = 48522666B（実装では整数式を直接計算・保存し、64MiB以内を検査）。BWT保守141598926Bへ保持controlframe最大1048861Bを加えた142647787Bを別source estimateとして記録。finiteは別process、control decode plainはcandidate前に破棄し大きいModelの同時所有は1。static counterは小定数でmodel枠に計上する。

source300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、実WS/private各160MiB。first stage 2files合計30KiB以内。生input/frame/plain/raw trace/Cargo/PDB disk copy0。source/tool/input/PLAN/凍結wire成功reportと全接続graph before/after/live pinsは後段runnerで検査する。計画未実行時点では動的allocation/frame/resource成功を主張しない。正常・境界・型・資源の失敗先行RAM E2Eに限定し、post-code unit testや資源枯渇・chaos・並行性試験を追加しない。総合GOALはactive・未達。
