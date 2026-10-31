# KT register専用化は既に実命令へ折り畳まれていた

前段feasibility SHA `0303FB297D7B430C71643E6B7D6C7847A7E4FD75FDD0956F6D707D051E714315` の「既に同形状なら打切り」を実行した。新candidate/追加asmは作らない。

対象は通常codec EXE SHA `44CF635A18CF73E14E968A63C5A0EC4534FE47A4E277D7F818C32E1EEDE740C3`、llvm-objdump SHA `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA` の全逆アセンブル。PDB帰属ではなく、class7/Node counts/cap562036803/等カウント/17level traversalのoperandsと構造からsourceを対応付けた。

root:

- 0x14000a167/a16bでcountsをEDX/EAXへloadし、a172/a175でchecked sum、a17bでcap0x21800043を検査。
- a23d/a23fでequal countsならQ/2へ。非等カウントはa241でtotal+1をR8Dへ、a244でEAX=0x80000000、a249で `divl %r8d`。EDXはcountのhigh32として既に保持され、汎用積計算・high32比較はない。
- a24c/a24eには商zeroの拒否が残る。今回の案は商zero検査の削除ではなく、汎用形状変換の省略だったため、これを別の性能改善へすり替えない。

後続level:

- a2bf/a2c4のcounts load、a2cc/a2cfのchecked sum、a2d5/a2dcのcap検査、a2e8/a2eaのequal shortcut。
- a2ecのtotal+1、a2efのEAX=0x80000000、a2f4の `divl %r10d`。ここにも汎用mul/分母Q分岐/high32ガードはなく、同形状である。

数学が成立しても、現在compilerが既に削除した処理は追加source変更で削減できない。この案は新実装候補として棄却する（速度実測によるno-goではない）。汎用posteriorのdivlは別領域で、KTの上記推定へ混ぜない。

次の別候補は小さいKT分母のexact reciprocal table。まず実書庫で分母分布を数える必要があり、この結果だけでtable有効率や速度を主張しない。CPU guard/source/固定gateを維持する。
