# SAからanchor採取：先行固定計画

目的は前候補のmetadata生成LF構築・依存歩行70.6117msを除くこと。固定GOALゲートのsize483599B/encode574.5624ms/decode47.3884ms、quiet条件、holdout/API/4nativeは維持。単体診断を完成書庫性能や採用へ読み替えない。

## 所有権と範囲

親は本PLAN・RESULT・readonly verifier・決定台帳。workerは新規 `anchored-sa-generation/FAILURE_PLAN.md`、`bwt.rs`、`happy.rs`、`probe.rs`、`run-native.ps1` の5filesのみ。failure-first、apply_patchのみ、他者変更を保持。原BWT、anchored-inverse、製品、旧証拠、依存、Git、version、x86、外部、削除には触れない。compile/nativeは親最終READY/SHA/全文確認後のみ。

opop全観点は親が本限定範囲を調査：Performanceは既存SA利用でLF構築・全random walk除去、Hardeningは採取欠損・重複・bounds拒否、Testerは同一metadata/全BWT/primary/全plainの有限E2E、Normalizerは原serialize/parse直接再利用、Cleanerは原SA-ISprefixを全文維持し無関係な整理なし、Modernizerは既存Rust固定・依存変更不要。Asyncは追加heap scratchと明示drop寿命を検査。Intelはローカル数学・コードで決着し非該当。Startupは私的単体probeで利用者配布経路なし非該当。

## 数学と変更境界

唯一sentinelでSA[LF(row)]=(SA[row]+n−1)%n。q=n/8、anchor_i=LF^(i*q)(primary)なのでSA[anchor_i]=(n−i*q)%n。n>=8だけ8行採取、n<8はcanonical emptymetadata。原 `causal-bayes-sais/bwt.rs` SHA810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132Fのsuffix_arrayを含むbwt前prefixを全文一致で保持。新bwtは出力にmetadataを追加する以外、入力上限・整数幅・SA・last・primary・sentinel処理を維持する。新関数のこの処理も取り消しledgerで原全文へ復元可能にする。

既存SA→lastループ内でn>=8ならp==0をanchor0、p>0のdelta=n−pが7*q以下・qの倍数ならidx=delta/qの行を採取する。採取は8個のstack usizeだけ、row<n・p<n・duplicate/missingを検査。q=0の除算を行わない。原32B serialize/parseを直接使用。全SA保持期間は原と同じ、追加LFtable/歩行/独立全SA走査なし。serializer前後の解放を含む新BWT全コストを計時し、補助metadata費用を無料にしない。

## 先行失敗契約と有限/E2E

failureplanを先に保存。tiny n1..23×4recipes92件は旧BWT/旧LFgenerationと新BWTmetadataのlast全文・primary・metadata全文を直接比較、原reference/packed24/anchoredの全plainも入力へ一致。独立suffix sortのSA/BWT92、anchor対応512、fallback28、全剰余8を確認。既存1793列挙等のdecoder契約は今回変更せず原候補report/pinsで保全し再実行を不要にする。

新採取helperはn<8/各剰余/最大n8388609・p範囲・row範囲・duplicate/missing・q0防止・誤ったsuffixの非採取を失敗契約として先行検査する。selector最大境界は8個の対象positionからの合成でよく、MAX入力を新BWTで生成してRAM予算を越えない。MAX_INPUT+1の入力拒否はbounded Vec約8MiBで割当前拒否を確認。OSOOMを主張しない。最低1回、拒否後の正常BWT復帰を確認。

## 実測と上限

固定input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を1read。旧pipeline=BWT＋旧LFmetadata生成、新pipeline=BWT＋SAmetadata採取。各warm1後9round AB/BA交互、18callsの旧BWTns/旧LFgenerationns/旧totalns/新totalnsを全保存し中央値と順序別中央値を再計算。各roundは旧pipelineと新pipelineのlast/primary/32Bmetadata全文を直接比較、最後に同一metadataで全plain復元。出力比較・caller解放は計時外、関数内SA/text/scratch解放は計時内。old関数の境界を別timerで測る際、旧totalは総walltimerで記録し和との僅少timer overheadは許容し具体的に保存。

quietCPUは未確認の内部screen、正式速度や7-Zip比較ではない。oldlast保持中のnewBWT推定は既存BWTphase141598926+last.capacity*2+64metadata+4KiBstack/samples=147225100B以内（160MiB上限）。実WS/privateの両peak<=160MiBを別確認。追加LFscratchやold/newplain同時保持のphaseも見積る。新SA-ISprefix/割当順は原と一致し仮想追加scratchを隠さない。

rustc固定SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、pwsh固定SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。compile1/native1、edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、timeout60/120s。9Rustsources想定、source+PLAN+failure300KiB、EXE1MiB/report256KiB/newoutput8MiB/minfree5GiB。unusedoutput `build/khc-anchored-sa-generation-20261004`、EXE＋report2filesのみ、ASM/PDB/plain/frame/rawtrace/newCargoなし。guard事前・事後・報告後。親readonlyは追加compile/native0。

runnerは原bounded Child/Source/Identity/SafePath/SaveReport ASTを固定SHAから使用。原reference抽出ledger再検証、旧anchored report3DDDA5809D5615E50017F012FCD22BD3AFEF424FF4A06B099F7ACEB34B40EEA9とEXEEDE58C62051203D85C52794F2EF91B3C5E1489644E0F523FBC2163FF9CA38B0E、全旧before/after/liveの不変をpinで確認。parser緩和なし。失敗時同条件restartせず原因を限定し証拠保持。新metadata CRC・完成書庫互換・4native・採用はfalseで記録する。
