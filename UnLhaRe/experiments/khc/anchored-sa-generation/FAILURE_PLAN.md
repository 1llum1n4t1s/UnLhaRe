# SA anchor 採取の先行有限契約

親PLAN SHA6E28E22BC2DFE1414315D55D7A8AC30D86D35FEAEAA31F3898758483867E68FF読了。原BWT prefix/SA-IS/整数幅/上限/割当順を維持し、既存last loopのstack採取だけ追加。新metadataは旧serialize/parse直接。全compile/nativeは親だけ、以下未実行。旧anchor decoder1793件等は旧成功証拠/pinsの保全であり今回再実行済みと呼ばない。

## finite recipes（コード前固定）

n1..23×4recipes（0/255/0-255交互/73i+19 affine）=92。原BWT→旧LFmetadataと新BWTのlast/primary/metadata全byte一致、独立suffix-sortのSA/BWT92・anchor対応512、fallback28、全剰余8。reference/packed24/anchored各全plain入力一致、全比較をCRC/hashで代用しない。

selector正常：n1..7の各全positionを合法rowで走査（28calls、q0 divisionなし/metadata空）；n8..23と8388607/8388608/8388609の19cases×8対象suffix=152calls・152anchor照合・19finish roundtrip。n=16,p=1は非対象suffix（1call/非採取）。selector失敗8件：n0/nMAX+1/p=n/row=n/同idx重複/missing finish/primary不一致/finish duplicate row。拒否前後のstack比較はduplicateとboundsの5select拒否に限定、finishはby-value。最大selectorは8対象positionだけで合成、巨大BWTなし。

MAX_INPUT+1 byte Vec約8MiBで原/新BWT拒否（2拒否）、新input上限を比例割当前に検査。OS OOM注入は主張しない。拒否後normal BWT1で旧新last/primary/metadata全文と正常plain復帰を確認。finite selectorの人工stack状態を到達可能SA状態と誇張しない。

## fixed cost・資源

fixed2811006B一read。入力byte集合からalphabetを一回だけ共通prepし、nsを別記録（各pipeline計時外、最大257u16、inputコピーなし）。old=BWT＋旧LF生成、new=BWT＋SA採取、warm1各後9round AB/BA＝18calls。毎pair全文last/primary/32Bmetadataを直接比較、最後全plain入力照合。旧BWTns/LFns/totalnsと新totalns全raw保存・overall/順別中央値。旧totalはsumとは別walltimer、その具体差を保存（timer bookkeeping誤差）。比較とcaller解放は計時外、function内text/SA/scratch破棄は計時内。extraLFtable/walk/SA再走査0、新metadata CRC/完成archive/adoption/formal/native4 false。

newBWT中oldlast2*2811007/metadata64/stack-samples4096を保持：141598926+5622014+64+4096=147225100B。旧LF生成とold/newplain寿命もsource式/actualVec capacityを報告、各WS/private peak160MiB別検査。selector stack8Option<usize>だけ、追加heapは32Bmetadata。全source+PLAN+failure300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、compile60/native120s、新unusedbuild khc-anchored-sa-generation-20261004のEXE/reportだけ。生dataコピー/ASM/PDB/newCargo0。

原BWT prefix全文一致、追加を除去して原BWTbody全文復元ledger residual0。旧reference抽出/anchored全before-after-live/source/tool/input/親PLAN/旧EXEをpin。READYで所有5file停止返却。製品/旧source/他者dirty/Git/version/x86/外部/delete/追加委任0。7zip総合GOAL未達/active、単体screenへ縮小しない。
