# normalized prior full CLI E2E 事前失敗計画

- 新CDFのcumulative floor/更新順/截断/escapeずれ: 前成功検証と同seed・7入力を4compiler条件で28encode/decode全byte、21frame全byte比較する。statsと実header/boundsも照合する。
- 共通実装の同時誤り: productionCDF/codec encoderを使わないliteral normalized intervalsでvalid empty、zeros255/256/257を構築し全bytedecode比較する。rank初期C1=1/C2=3、length初期C(k)=2k、causal更新後tupleを個別固定する。
- malformed受理: 23独立forgeのgrammar/header/CRC/metadata/terminal/primary/LF拒否で意図stderrを照合。no-clobberは既存byte/hash保持とoutput create_new、missing/args/operation、balanced相互拒否・旧KHNTOK01拒否を実行する。
- identity/path誤り: actualimportとPSparser/必要実在pathを実行前照合。新source/新数値report/原range/旧fullproof/compiler/runtime/input/旧EXE/frameをpin+Read lockし前後照合する。旧source/proofを変更しない。
- 容量/証拠/清掃: fresh build/khc-direct-token-prior-full-20261002、通常3MiB/最悪50MiB/上限64MiB、child120秒/stdout stderr65536/report512KiB。4codecEXE+forge+7frame+reportだけ保持。inputcopy/PDB/Cargo/rawtraceなし。削除fixtureはtransient_path/hash/bytesとcleanup ledger、exactowned/nonreparse/child終了/stream閉鎖後のみ削除する。
- サイズgate<=483599、前575791との差を実frame長で報告。sizefalseでも全correctnesscaseを完遂し正式benchmarkは行わない。elapsedは診断のみ。allocation注入/他native/holdout/正式性能/製品統合は未検証。
- unique active invariantによりadjacent同symbol拒否branchは到達不能、静的確認と実行済みcaseを区別する。

parentfreeze/hash後に一度だけ実行。未知failureは最小証拠を保持して返却し、同条件再試行/root上書きしない。旧fullのBWT pin typoはactual causal-bayes-sais import照合で防ぐ。Git/stage/commit/push/version/external/x86/追加委任なし。
