# 8-anchor inverse 独立診断の先行契約

独立analystはLF置換＋区間終端連結＋global step>0でprimary再訪なしによる全n行訪問を証明した。n72/primary7/last=[1×7,0,1×64]は8周期＋固定点で、anchor全部異なる・全終端一致でもprimary早期再訪検査がなければ誤受理する。実装前の必須拒否fixtureとする。SA対応式は後続のtiny suffix-sort oracleで確認し、今回は元BWTを変更しない。

## 所有と構造

workerは新anchored-inverse/内FAILURE_PLAN.md、anchored.rs、happy.rs、adversarial.rs、probe.rs、run-native.ps1の6filesだけ所有。最初に失敗計画を保存。旧permutation-inverse/packed.rs、reference/contract/memory/BWTは直接凍結参照。親は停止READY後に全コードと構築guard・復元写像を確認し実行する。製品/公開API/wire/version/依存/Git/x86/外部/削除なし。

n>=8はq=n/8、offset_i=i*q、最後だけq+n%8。8row stateを同一threadでinterleave。anchor0=primary、全row範囲、各rowはload/write前にglobal offsetでprimary早期再訪を検査。最初7終端は次anchor、最後primaryを要求する。LF構築は旧packed24と同じsymbol区間連続rank・range/count/alphabet/sentinel guardを維持。wordsはread-only、出力[n-1-global_step]へglobal_step>0だけ書く。各segmentはq行と最後のremainderを処理し、総n行を検査する。n<8はmetadata空のみcanonicalで旧packed24 fallback。

metadataはn>=8なら8×32bit LEの32bytesだけ、n<8なら0bytes。serialize/parseで実bytesを計上し、不正長/範囲/anchor0/重複/ずれ/終端を拒否。CRC付き完成書庫は未作成でありmetadata parserのCRC保護とは主張しない。fullplain直接比較をCRC/hashで代用しない。

encoder追加費用は、旧と同じLF構築とprimary全walkでanchorを求める処理＋metadata serializeを別timerで実測する。生成中もprimary早期再訪とn後復帰を要求する。この追加LF walkは無料ではない。将来SA scanへ置換する費用・wire統合も未検証。生成wordsは候補restore前に解放。

## failure-first 有限E2E

- n1..23で空plain、任意byte0/255、反復、交互等の固定recipe。旧reference/packed24/candidate全plain/input一致、全n%8余り、fallback/8本開始、metadata parse/serialize一致。
- tiny独立suffix sortでBWT/SA oracle、anchor_iのSA値=(n-i*q)%nを照合。これはSA-IS全域の証明とは呼ばない。
- 旧有限last列n1..8（3symbol・sentinel1）の1793casesを再使用し、受理時全plain比較と拒否を確認。生成拒否とdecoder拒否を別counterにし、無効last用の指定32B metadataもdecoderへ渡して実拒否を確認。全metadata256bitの列挙とは主張しない。
- 32B長不足/余分、row範囲、anchor0、重複、1行ずれ/別cycle/終端不一致、n72最強反例、約数cycle、symbol/sentinel/alphabet、最大transform長直外と24bitpack境界を区別して拒否。拒否後の正常restoreを同processで確認。
- 8388607/8388608/8388609の正常synthetic末尾sentinel入力を一つずつ作り、旧reference/packed24/candidate全plainと全expected0、metadata32B/全capacityを照合。前の結果は再実行済みと扱わない。巨大forward BWTや別expected Vecは作らない。

## 固定timing・資源

固定all.group2811006 bytes/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76をread1/BWT1。metadata generate1のnsと32Bを記録。oldpacked24/candidate各warmup1＋9roundのAB/BA交互、全18sampleと各全plain比較を保存。各callはscratch allocate/init/guards/walk/free＋candidate metadata parseまで計時、比較/drop/集計は外。quiet未確認の内部診断で正式速度ではない。sample選別/再測定/sweepなし。

compile1/native1、rustc edition2024 opt3/thin LTO/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、compile60s/native120s。新output khc-anchored-inverse-20261004未使用限定、EXE1MiB/report256KiB/全run8MiB/source＋plan300KiB/free5GiB。新Cargo target/ASM/PDB/生trace/ディスクinput/frame/plainコピー0。固定metadata32Bのreportだけ許可。

巨大oracle phaseは旧reference-resultを保持して旧packed24比較後dropし、candidateで比較する。reference作業logical12n-1＋last2n＋保持結果n-1＋4MiBで15n-2+4MiB<=160MiB。candidate phaseはlast2n＋保持oracle結果n-1＋words4n＋候補結果n-1＋metadata32＋4MiBで8n-2+32+4MiB。固定BWT bound141598926 bytes/別phase。全actual Vec capacityと源式、WinAPI実WS/private160MiBを区別して照合。metadata build wordsとcandidate wordsを同時保持しない。helperは凍結bounded source/path/child/report/locksを使いbefore/after/live SHA/bytes/UTCを保存。旧permutation結果reportとEXE/source/readonlyをpinする。

Performance: 8独立LF chainの依存load重ね（時間未証明）。Normalizer: 旧guard/packとcanonical metadata。Hardening: early-primary/連結/metadata/overflow。Tester: 上記先行finite/fullplain/実peak。Cleaner: 大copyなし・証拠保持。Modernizer: 依存更新不要。Async: 一thread/phase間drop/locks。Startup: scratchとmetadata parseを計時に含む。Intel: 外部仕様不要。

正当性成功だけで採用しない。固定正式483599B/encode<574.5624ms/decode<47.3884ms、同thread/memory、quiet15%/warm1+9、holdout/カテゴリ/完成書庫/API/4nativeを維持。現在payload約2sの課題も別に残る。7-Zip超えGOAL active、停止なし。
