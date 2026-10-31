# direct feature機会診断：failure-first契約

四familyをglobal/symbol/recent/jointの順に各1回処理する。同じtraining入力の機会診断だけで、coder実装/候補採用/速度/holdout/entropy最適下界ではない。凍結static root/source/report/headerは一切編集しない。

| 工程 | 事前失敗条件と検証 |
| --- | --- |
| 入力/基準 | 固定SHA/2811006B、凍結source/header/report pin差を拒否。read/BWT各1回。同runs/static parseでrank/length Kahan合計を5000107.114226128bit±1e-6に照合。runs889227/token1778454/escape742/primary1762795/grammar照合。frame再生成なし |
| history | 初期0、token前値、rank0 saturating exponent、length1/2/3-4/5/escape、sentinel/terminal、更新前後ずれ。新historyを凍結Frontのprevious rank/bucket/contextへ全event逐次照合。事前hand run A1,B2,A3,C256,B1,C5,sentinel1で初期、nonterminal、terminal、recent、exponent、key境界を確認 |
| keys | 固定global5/symbol14/recent21/joint23bit。joint式の未使用bit隙間を勝手に詰めない。component/context/symbol/previous exponent/recent rangeを検査。token9bitとpacked u32 overflowを拒否 |
| 集約 | raw event Vecなし。checked u32 counts、cells<=1778454、rows<=cells、component counts各889227。packed key/token一意sorted集約、row sum checked、全hist countと再score event数一致。map破棄後だけprefix作成 |
| CDF/loss | sorted token IDs、positive used count、prefix総和、Hamilton tie/32768、zero freq、valid limit、finite loss、component合計誤差、naive bit費用overflowを拒否。empirical countCDFとQ32768CDFの両prefixでtraining入力を再走査 |
| 表現 | branch node/hashを省いたdirect featuresを旧expert再現と呼ばない。singleton rows/token massとmetadata費用を併記し過学習を成功と呼ばない。naive metadata式は実serializeではない |
| 資源 | 1compile60s/1native120s、EXE1MiB/report256KiB/source300KiB/stdout64KiB/stderr16KiB/build全8MiB。beforeafter/live pinsと最終save後diskguard/process0。失敗は保持、sweep/retry/削除/Git/外部writeなし |

## 実装前RAM見積りと上限

固定events=1778454、Cell{packed:u32,count:u32}は8B。HashMap<u32,u32>をtry_reserve(events)で一回確保し、そのcapacityを保持中拡張しない。推定bucket数2097152、key/value8B+control1B/bucket+control tail16Bで18874384B。std HashMap内部layoutはAPI保証でないので推定であり、runtimeはcapacity-derived bucket見積りを検査する。

map→sorted Vecへdrain時に集約cell Vec最大1778454×8=14227632B。map drop後、cellごとのcount-prefix/frequency/frequency-prefix各u32=3×1778454×4=21341448Bと、Row{key:u32,start:u32,end:u32,total:u32,singleton-markなし}16B×1778454=28455264Bを保持する。mapと全prefix/Rowは同時保持しない。CDFはsparse used IDsで、全row×dense257配列を作らず最大257の一時quantizerのみ使う。

集約score phase上限=cell14227632+prefix21341448+Row28455264+fixed確認runs889227の次power2 capacity1048576×12=12582912+input2811006+header14077+static dense model127624+dispatch8512+hist/meta診断最大1369112=80937587B、約77.19MiB。run countはmap前に889227へ固定照合しcapacity1048576以下を検査する。row/Vec/HashMap headers・allocator margin4MiBを加えても約81.2MiB。

shared BWT SA-ISは学習phaseと別。fixed n=2811007、root text4n+input約n、types/SA/LMS/reduced、再帰n/2縮小、24B×alphabetのbucket群を保守的に50n+1MiB=141598926B（約135.04MiB）と見積る。names/reduced/drop順とBWT lastのphase差を考慮した推定で、allocator/process peak実測ではない。最大推定phaseはいずれも160MiB=167772160B未満。BWT/既存Frontを改変しない。runtime計数とcapacityをreportへ残す。

## 仮metadata費用

全family modelにcommon row count32bitを一度だけ、各rowに固定family key幅＋used count9bit＋IDs9bit×used＋明示freq15bit×(used-1)。rank/length欄はrowfield費用だけを分離し、common_row_count_bits=32を別欄にする。全model合計は(rowfield rank+length+32)/8をceilする。実wire未設計。token lossもcomponent別と合計ceilを区別。framing285B/model-bitlength4B/escape742B/reserve2048Bは合計予算で一度だけ加える。

hand-sequence fixtureは実BWTではなくRunVec grammarを直接使う小E2E。固定入力の全frame/plain一致は前static screenの実行済み証拠であり今回再実行しない。別新context独立監査は未実施。
