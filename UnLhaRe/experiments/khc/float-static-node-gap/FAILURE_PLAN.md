# float/static node gap：コード前の一設定失敗契約

2026-10-04。親PLAN SHA077253872417EA92195DB4DEDE27CF14792F93B42902C0F5C1F95C2444EB0BC8、QUESTION SHA36D080E0C9D9470E3F28C6A56BDDD8665E1FA56CEA7AC896B66436C02E1BE382を全文読了。実floatの更新前Q CDFと無料trained静的node/history CDFの差の局在化のみ。因果寄与ablation/係数depthQ sweep/posthoc route/保存model/実frame/速度/holdout/portable/総合採用へ広げない。

| 分類 | 固定失敗条件 / 親先行E2E |
| --- | --- |
| alias/model | scope::fixed_math=float_math、integer_pool=float_pool、integer_cts=float_cts、crate fixed_mathはcanonical原本。model原本全文＋末尾readonly storage/class accessor以外差なし。predict/observe/Tree/既存拒否26を変えない |
| features | peek context<=8/symbol<257、非mutation。commit symbol<257/rank<=256/length1..8388609の全preflight後、旧run_done previous/recent式と順序。親7fixture/peek2全state、invalid peek2/commit4全state。現在child・length/未来runをpeekへ混入しない |
| grammar | 元node-history全文へfeatures import/state初期化/callback Feature一引数/peek一引数/run終端commit一文/commentだけ。commitは旧rank/bucket更新前。全Meta/Tree/last10bitとprefix1更新不変、教師class/prefix/node/edgeを照合 |
| CDF/state | 全合法childの連続interval/total32768/min2/observed child select一致。prefix1もpredict/observe一回。教師audit entropy f64bits/terminal digest e596183d9e1eb8d7/branches/classesと原native-validation保存値一致。新teacher Kahan loss差<=1e-6 |
| static | 凍結Dense/quantizeのみ使用、原Density親helper正常10events/6active/872448whole rows/alias2、拒否8。static全rows/CAP/tail/CDF/count/empirical4012402.2267339313/Q4012463.5702508213照合、二walkMeta/Q一致 |
| aggregation | component2/class6/node2*142の全branch/coded counts/loss総和直接一致、lossは非負、static-minus-teacher gapはsignedで負も合法。node固定配列のみ保存、raw event/allrow列は禁止 |
| resources | compile60/native120、source300KiB/EXE1MiB/report256KiB/streams64KiB16KiB/output8MiB/free5GiB/peak160MiB/process0。初回失敗保存、retryは親判断、設定sweep無し |

RAM事前式：Dense13959192B +base791040*Count<=16=12656640B +weights4608*40=184320B +Tree/inline65536B +CTS/Math依存（canonical初期重複込み）1MiB +node/feature/snapshot scratch65536B +allocator4MiB =32174104B<32MiB33554432B。accessorはtablecapacity[4608,262144,262144,262144]/Count実sizeof/weights4608/tree各142と全baseheap+inlineを照合。CTS Node6*1365*24=196560B、Math grids4097/4097/32769各8B=327704B、初期canonical同寸法重複327704B、依存851968B<1MiB。割当てquota保証ではない。

固定phase最悪run1048576*12+input2811006+model32MiB+frontend1369112+別allocator4MiB=54511766B<64MiB67108864B。BWT別phase141598926B推定、WinAPI80B/cb80/終端一回peak160MiB、API失敗nullは未測定。Density snapshot、teacher拒否snapshot、Feature fixtureを順番に実行し固定入力前drop、同時大snapshot保持しない。

固定2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、一read/BWT/Front train+teacher二walk。rank/length各889227、escape742/history1778454/grammar58735a2b7383d755、branches[2725772,1099568]、classes[889227,620240,1216305,889227,64372,145969]、coded3825218/implicit122。side3079は予算式で不可避frame下界ではない。旧7classbinary結果を転用しない。

親happy/adversarialは編集禁止。worker指定七fileのみapply_patch、全source停止READY後親singlecompile/native、worker実行0。後段RESULT/verifierは親追加許可後。新unused build/khc-float-static-node-gap-20261004はEXE/report二fileのみ、model/input/frame/plain/rawtrace/Cargo/PDBコピー無し。rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/同audit cfg。旧root/tool/input/report/plan全pins前後/live。Git/製品/公開API/wire/version/deps/x86/外部write/delete/追加委任無し、他人dirty変更を戻さない。総合GOAL未達/active、新文脈implementation独立audit未実施。
