# header minor 256binの有界診断

root-history-order実費484612Bは目標483599Bに1013B不足。token478603+side3079=481682Bなので、lossを一切変えずモデル情報を1917B以下へ減らせる必要がある。独立監査はleaf mode固定prefix compact0/pure10/uniform11で993bitだけ削減できることを確認（保存葉uniform62/pure76/compact993）。Huffman minorの分布未測定なので達成を予測しない。

次は新private `header-minor-census/` で既存RAM packetを一度だけ逐次parseし、minorの256binと構造を集計する。実entropy encoderはまだ作らない。旧モデル木・order・CDF・LUT・DP選択・同木Qloss・原全Metaを完全維持、元source/report/EXEと製品dirty/Git/version/依存/x86/外部/削除0。全GOAL active、全CLI574.5624/47.3884ms/quiet/warm1+9/holdout/API/4native未達を維持。

## 測定費用

minor数N、hist h、Huffman長lについて元header payload23405bit、固定prefix変更後22412bit。Huffman候補はcodec flag1B＋bit長u32 4B＋256length nibble128B＋ceil((元payload−compact数−8N+Σh*l)/8)。1917Bへ届くには現packetでminor8140bit以上削減が必要。元packetの32bit長fieldは新fieldに置換し二重加算しない。raw-minor fallbackは1B+4B+ceil((元payload−compact数)/8)=2807B。空histはraw、singletonはlength1、通常Huffmanの最大length>15はraw。決定的tie (weight/minsymbol/id)で256symbol1候補だけを計算し、無制限length最適化やprecision/幅/sweep0。

通常Huffmanの最小長は有料length制限候補の下界にも使える。選択費用は有効Huffmanとraw-minorの小さい方。table/flag/paddingを無料にしない。Nは旧構造censusから2084..2217までの見込みに過ぎず、実値をparseで確認する。Σh=Nと符号費Σh*l、nonzero/maxdepth/Kraft合法性、各field bitwidthとcensus、元bitstream位置exactを独立検査する。length>15ならHuffman費用は候補として採用せず理由を報告する。

## parser・上限

元global packetのbytes/bits/padding/834root固定k2→3→4順を確認し、default outer0はbodyなし、outer1はtree splitbitとrootだけorderbit、leaf mode2bit／dominant1or2／minor8bitを読む。depth5超過/reservedmode/index/truncation/残余・min・largest/余剰/zero paddingを拒否。全root/分割/保存uniform・pure・compact/order/defaultを元censusと照合。元reader/Forestとの全CDF復元は凍結probeのまま継続する。rawcode列・CDFtrace・packetコピー0、packet scan1。

MAXminor=278*1024*(1+2+3)=1708032、u32 hist256=1024B。Huffman木最大511nodeと有界heap、コード表256、scratch計算上限16KiB。計測中の作業域は終了後破棄し、hist/length/小scalarのみ結果へ保持。結果はsizeof/capacityを報告し、元node/reportと同時保持する費用をscratch65536内へ加算する。node JSONは実28946Bだったためcapacity32000Bへ縮小可（上限32000/row160/末尾8を先行検査）。巨大reserve追加不可。model32MiB/phase64MiB/OS WSprivate160MiB、元BWT141598926Bを維持。

## 所有・failure-first

workerは新 `header-minor-census/{FAILURE_PLAN.md,census.rs,e2e.rs,probe.rs}` 4filesだけを専属所有。model/bundle/frozen_e2e/grammar/counts/Front/BWT/memoryは旧root-history-orderほか凍結sourceへ直接参照する。旧probeを新probeへ移し、packet完成直後のcensus1回と結果保持・費用式/printのみ追加。旧モデル学習/再Fit/全Meta/freeQ/原lossを変更しない。候補codecは未実装を明示する。

先行FAILUREへempty/singleton/一様256/偏り/length>15 rawfallback/最大weight超過/合算overflow/非zero符号費とKraft、全root default/各leaf mode/k2・3・4/mixed rootorder、小さい独立raw packetのtyped field・bit長検査、元packet不正/trunc/depth/index/padding/回復を固定してからコードを書く。新Huffman decoderがない段階でdecoder/table不正検証済みとは主張しない。旧有限E2E全件は直接frozen_e2eで維持。post-code unit追加なし。

workerはapply_patch、compile/native/Git/外部/削除/追加委任0。固定非書込rustfmt/syntax＋元probe許可挿入の逆復元ledger＋4SHAmtimeでREADY/完全停止。親はPLAN/AUDIT/runner/verifier/RESULT/decisionを所有し全文確認後compile1/native1。fixedruntime/compiler/flags、元bounded helperで60/120秒、source+PLAN+FAILURE300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、未使用 `build/khc-header-minor-census-20261005/` にEXE/report2files8MiB/free5GiB。report hist/length各256binだけ、入力/frame/packetコピー0。

前段基礎readonly144組開始/終了、旧実費screen484612・token478603/header2930/原全lossとMetaが新nativeでも不変を検査。費用候補≤1917Bなら実header entropy coderのfailurefirst＋typed逐次比較＋全CDF/元lossへ進む。届かなければこの固定familyは棄却し、似たparameter試行を繰り返さない。teacher0/frame0/state/速度未検証の診断を全GOAL達成へ置換しない。
