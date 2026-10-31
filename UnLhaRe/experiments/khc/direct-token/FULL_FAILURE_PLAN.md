# Full CLI E2E の事前失敗計画

- rank/length の文脈・更新・truncate・escape の不一致: 7入力を4条件で別CLI encode/decodeし、入力と復元の全byteおよび4frameの全byteを64KiB blockで比較する。
- 偽frameがCRCだけで落ちる: 独立literal interval forgeでpayloadを作り、metadata/header/payload CRCを修復して、意図したgrammar errorをstderrで照合する。empty有効frameを同じforgeで通す。
- canonical LEB128、remaining超過、active early/end、range gap/terminal/trailing、sentinel/primary/LF、header field/CRC、metadata/payload/plain CRC、短いframe、旧magicの受理を拒否事例とする。
- 出力破損/事前公開: encode/decodeの既存出力保持、missing input/invalid operation/args後の出力不在を確認する。
- 条件差・証拠混同: source/contract/guard/primitive report/compiler/runtime/input identityを前後比較し、sourceはRead共有lock。削除済みpathはtransient ledgerで明示する。
- 容量/停止/清掃失敗: fresh rootのみ、child120s・stdout/stderr各65536文字・report512KiB。通常約3MiB、worst約50MiB、上限64MiB。4codec+forge EXE、7frame、reportのみ保持。PDB/Cargo/raw traceなし。exact owned/nonreparse pathのみchild停止・stream閉鎖後削除する。
- サイズ不合格はcorrectnessとは別のsize_gate=false。全CLI elapsedは診断であり正式benchmarkは行わない。allocation実失敗、他native、製品統合、holdout、競争性能は未検証。

親のfreeze/hash後に一度だけ実行する。失敗時は最小証拠を保持し、再試行/上書きせず親へ返す。

## 事前照合の訂正と追加枠

元入口はBWT pin pathのtypoでexit1。codecの実import causal-bayes-sais/bwt.rsは要求SHAと一致。停止時compile0/codec0、元root未作成、生成物0byte、lock閉鎖。追加契約DIRECT_TOKEN_FULL_PREFLIGHT_FIX_20261002.mdに従い、新root build/khc-direct-token-full-20261002-bwt-pin-fixを使う。元rootを再利用しない。

実行前にBWT path、追加契約pin、旧EXE/frame pin、size<=483599、transient identity分類、case別CRC事実、no-clobber stderrをまとめて訂正する。独立zeros255/256/257を手組みliteral intervalでdecodeし全byte照合する。変更後freeze/hash通知して新枠を一度だけ実行する。

non-maximal adjacent runはunique active listのhead除去後、rank0は消滅・rank>0は他symbolの後へ挿入するため到達不能。静的invariantと実行済みgrammar caseを区別する。
