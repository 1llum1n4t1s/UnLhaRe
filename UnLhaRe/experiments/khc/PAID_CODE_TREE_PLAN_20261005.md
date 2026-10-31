# 固定有料257symbol符号表による木/token共同選択

現header-minor-census実測 report BC00DC11E643D3F71664E2306FD588DCFDEAB340B74CE4D372F6A38E2C914A55 は固定木候補484305B、gate+706でno-go。固定木・単一alphabet・同tableなら構造無料でも1963B>必要1917B。これを無視した符号長/precision sweepや同木encoder実装は行わない。

独立担当はroot-history-order/model.rsの一律minor8bit課金が保存費と不一致であることを確認。次は新private paid-code-tree/ だけで、下記固定tableをDP構築時から課金し、木とtoken lossを共同再選択する一候補。サイズ達成保証なし。実header encoder/decoderの全CDF一致を必須とし、teacher0/frame0/全CLI速度/holdout/API/4native未達を維持。旧loss不変とはしない。全GOAL active。

## 固定tableと費用

元実測hist256＋ESC(symbol256)擬似重み1を一度だけ(weight,minsymbol,id)で構築したlength表257を固定する。親の独立PowerShell再算術でもmax11、ESC11、known14638bits/total14649bits、Kraft32768を確認。新選択木からtableを再学習しない。既知minor費用はlength、length0の未知minor費用はESC11+raw8=19bit。未知symbolを無料にしない。以下の順序0..256：

```text
7,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,0,0,11,0,0,0,0,10,0,11,0,0,0,0,0,11,0,11,0,0,0,0,0,0,11,0,0,0,11,0,0,0,11,11,0,0,11,0,0,0,0,11,11,0,0,0,10,0,11,0,11,0,0,0,11,0,0,0,0,10,0,11,11,0,0,0,11,0,0,0,9,11,10,9,10,10,11,11,11,10,9,10,11,10,0,9,0,10,11,0,0,10,9,9,9,11,10,10,10,11,9,9,9,10,9,10,11,10,10,9,10,10,9,9,8,10,8,7,8,9,9,9,8,8,9,10,8,8,9,9,8,9,9,9,9,10,8,8,9,8,8,8,7,8,8,8,8,8,7,9,8,8,8,8,9,10,8,7,9,7,9,8,9,7,9,7,8,7,8,7,8,7,7,7,8,8,8,8,7,8,7,8,8,8,8,7,8,7,7,7,7,6,6,6,7,6,7,6,6,6,6,6,6,6,6,6,6,6,6,6,6,4,5,5,6,7,7,7,8,7,8,8,8,8,8,7,7,7,7,7,6,6,7,6,6,0,11
```

canonical symbol順は(length,symbol)。metadataはflag1B（固定値1）/bit長u32 little endian4B/table257nibbles129B（最初のsymbolはhigh nibble、最後のlow nibble0）/payload/zero pad。header134+ceil(payloadbits/8)。global root834個の順は旧model/c/k2→3→4、outer defaultflag1bitは常に課金。default内部0。leaf split0+mode compact0/pure10/uniform11、pure/compact dominant幅1(k2)または2(k3/4)。compactの各non-dominant codeをcanonical、未知ならESC+raw8。root splitはsplit1+order1（2bit）をDP構築時から課金、内部split1、depth<=5。頻度LUT・floor・quantize・支持min2・元history permutation・元Dense/Metaは保持。

旧木へ同fixed tableを適用した実費はpayload19914bit/header2624B/screen484306B（gate+707）。新DPはtokenloss+payloadbit目的で、利用可能な旧low/high木を再課金した目的より悪くならないことをroot/node/globalで確認。byte丸め込み最適や全speed改善とは主張しない。新木/tokenloss/ESC件数/headerの各増減を分離報告。固定max11/未知19なら完全展開3group129026bits<=旧MAX_BITS142338。一般max15まで広げると上限が不足するので、今回fixed max11を先行assertしてwidth sweepしない。

## 所有と実装境界

worker-high専属新6files paid-code-tree/{FAILURE_PLAN.md,codebook.rs,model.rs,bundle.rs,e2e.rs,probe.rs}。親はPLAN/AUDIT/runner/verifier/RESULT/decision。古い全source/report/EXE、製品dirty、x86、公開API/version/依存/Git/外部/削除変更0。他者差分を戻さない。まずfailure-firstを保存してからapply_patchで実装。compile/nativeは親各1のみ、workerは固定rustfmt非書込syntaxと可逆ledger後6SHA/mtime/bytes READY完全停止。追加委任なし。

probeのcrate::model/bundle/frozen_e2eは元root-history-orderへ直接参照し、旧有限E2Eをそのnamespaceのまま全件維持。新paid_model/paid_bundle/paid_e2eを別namespaceで使う。新modelは原Hist/quantize/LUTを再利用できるなら参照し、Fit/Selectedの選択・支払費・実writer/parserだけを新実装。旧Fitを改変しない。旧Front/BWT/grammar/Dense/memoryを凍結参照。新fixed length表はsource定数と実header両方に存在するが、decoderはheaderから読んだtableで復号し、compiled固定tableを無料の復元情報として流用しない。独立canonical表構築と全256minor（既知/未知）直接往復、表の同一性は検査する。

parseではflag、129B tableの最後pad、0..11長、ESC存在、Kraft oversub/incomplete、canonical/trie範囲（最大513node）、trunc code/ESC raw、ESCで既登録symbolを送る冗長表現、bit長/bytes/pad/trailing、pure/compact dominant、残余largest/min2、root/depth/orderを拒否。all-defaultも129Bを支払う固定familyであり、table費をdefaultから隠さない。個別rootの実bitcountと新DP内部bits、global flags834、table134費用を直接照合。

新Fit→individual root parse全CDF854016、完成Forest→再Fit全CDF854016、元Dense weighted low/high全行、root counts、原全Meta/全freeQを照合。新DP row loss=parsed actual CDF loss=新replay loss、old同木との直接一致ではない。新モデル木のoriginal Qlossと近似Δは別に計算可。旧選択木を新feeで再課金する比較は、原wireをtyped parseしてCDFとコード費を直接照合し、旧19914/header2624も確認する。固定read1/BWT1/walk2、Fit builds・baseline repricing検証passは全件数を明記。追加coded payload frameは作らない。

## failure-firstと資源

先行計画へknown/unknown全256、ESC boundary、canonical tie、table flag/length/nibble-pad/Kraft/ESC absent/overflow、allk×leaf mode×dominant、shallow/deep/maxdepth/order、trunc/pad/trailing、残余underflow/largest、DP root/default/order料金境界、追加料金でleafへ戻る境界、同process回復を固定。post-code unit追加なし、有限RAM E2Eのみ。実entropy encoder/decoderとしての成功は上述の実bytes/CDF/loss比較後だけ。

hist/codedraw/CDFtrace/input/frame/packet disk copy0。source+PLAN+FAIL350KiB、EXE1MiB、stdout64KiB/stderr16KiB/report256KiB、未来未使用 build/khc-paid-code-tree-20261005/ にEXE/report2files8MiB、free5GiB。helper/PowerShell/rustc/flagsは前段と同じ、親60/120秒bounded子。source graphは実数を親確認。

model32MiB/phase64MiB/OSWSprivate各160MiB/scratch65536、nodeJSON32000/row160/end8。codebook/trie/encoder/decoderの各capacity実費を計上。codebook/一時trieをreport前にdropし、保存length257/料金scalarだけを最終scratchへ保持するなど非重複phaseを区別する。約61940Bのreport基礎scratchに巨大codec領域を同時保持しない。model/phase算術推定とOS物理peakを区別。全encoderとtabledecoder/Forest検証を終えてからcodecを解放可。

基礎開始/終了root readonly144組、直前minor readonly157組。新候補がscreen<=483599かつCDF/fee/拒否/資源を通る場合のみ実frameとteacher状態/速度の別工程へ。no-goならtoken/header/ESC/目的の増減を保存して同parameter再実行しない。

