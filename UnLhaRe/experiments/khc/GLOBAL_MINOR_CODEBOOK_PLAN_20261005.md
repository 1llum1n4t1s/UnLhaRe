# global共有モデル・minor頻度codebook候補

前段shortleaf529063Bはno-go。次はglobal class2/5選択の保存済み494389Bを基点に固定1候補を診断する。全GOAL active、完成書庫483599B/全CLI encode574.5624ms・decode47.3884ms未満/同CPU threads RAM/quiet≤15%/warm1+9/holdout/API/4nativeを維持。製品・旧source/report・Git/version/依存/x86/外部/削除0。

## 独立反証

analystは旧bundleを独立parseした。2244葉/470split、uniform931/pure21/raw1292、default roots534。旧木に下記leaf符号だけ適用すると32871bits→4113B。旧10577Bから6464B改善するが、旧token480733＋4113＋3079＝487925Bで4326B超過。新DPで剪定損失を減らし、CDF近似損失を実計上しなければ成功しない。無料screen473039Bはtoken469960＋side3079、480733は既存MDL後tokenであり、両者を混同しない。

静的化対象は1362251/3825218branch（35.6%）のみ。teacher残り64.4%の実更新・状態保持は未検証。reference非選択teacher lossを足したscreenを実書庫や速度利益と主張しない。screenが通った時だけ、実teacher replay/state保持とframe encode/decodeへ進む。rANS等への速度利益も未測定。

## 数値・wire

Hist/原quantize/history10/四分木depth5/固定class2・5/278models・834rootsを維持。原Qのuniform/pureと完全一致するleafはshortleaf仕様を使う。その他は元Qの最大child（tieは先頭）を暗黙残余にし、index k2=1bit/k3・4=2bit、他k-1頻度を8bit LUT codeで保存。原頻度から各minorを下側格子へ丸める固定1方式だけ、上下探索・精度/幅sweep0。

LUTはu16×256。先頭64値は2..65、残りはe6..13とj1..24についてmin(16383,2^e+ceil(j*2^e/24))。整数const演算で生成し、codecでfloat生成しない。全値単調・重複なし・端点2/16383を検査。原最大でないminorは16383以下（k2の16384/16384はuniform短符号）。floorはmin2、最大残余は元largest以上となる。writerの新CDFは[minor復元値、largest=32768-sum]、valid total/tail/min/largestを確認。

leaf splitbit＋2bit mode00uniform/01pure/10compact/11reject。内部leaf費用3、pure4/5、compact12/21/29bits。readerはchecked sum/subtract、残余min2、largest>=全minor、k3index3、mode11、depth/padding/exact/trailingを拒否。各minorが範囲内でも不正な組合せはあり（k3minor16383×2の残余2）、組合せを検査する。

Fitはこの復元CDFでleaf lossとDPを計算する。原quantize関数を変更せず、build_nodeの直後にcompact_frequencyを挟む。CDF近似ΔLは同じ選択済み木の原Qlossと新lossの符号付き差として別計上。旧木やCDFが不変とは主張しない。rootdefault内部DP0/oraclewire3、outerflag1を維持、全root内部bits＋834flags==実global header有効bitsを直接照合。

## 実装所有と検証

親は本PLAN/runner/verifier/RESULT/decisionを所有。workerは新global-minor-codebook/{FAILURE_PLAN.md,model.rs,bundle.rs,e2e.rs,probe.rs}5filesだけ（計画上の6ではなく5）。failure-first census保存後にコードを書く。元class-selective-static-mdl probeのtrain/replay/free/reference値と原grammar/counts/Frontend/BWT/memoryは直接参照。shortleafのleaf/rootAPIを新modelへ移し、数値/wire変更だけをledger化。weighted ingestと原Hist/quantize全文を維持。旧証拠は変更しない。

bundleは278model固定class2/5順、834rootflags、global u32bit長1個・末尾padding1回。pernode/perroot長field/paddingなし。root oracle bit直接連結比較、完成packet全parseからForestを作り、個別root/選択FitCDFと全854016history CDFを直接比較し、grammar replayでnode/component/class/wholeのcounts/lossを1e-6bitで照合。巨大Fit forestを保持しない。Forestは原同形6979896B、Dense13959192B、node scratch1、packet1。metadataはRAMだけで、元probeのdiskbundle出力を除く。

E2Eは先にLUT全値/端点/tie/floor/exact roundtrip、全k全dominant/pure/default/compact/内部split、root0/oracle3、費用境界、無効mode/index/minor組合せ/切詰め/余剰/padding/depth/CAP/shapeと回復をcensus固定。旧density finite E2Eは直接参照して維持（新wireは旧happyの93bit等と非互換なので、その値を旧wireに合わせない）。post-code unit追加なし。

実入力read1/BWT1/grammarwalk2、全Metaはtrain/replay直接Eq＋原raw全fields一致、原free selected loss/reference teacher値を照合。weighted854016/roots834/node278/codedselected[1216282,145969]/全coded3825218/implicit122固定。combined loss=新selected parsedloss＋保存済teacher_nonselected2286636.8077715、screen=ceil(combined/8)+実header+3079。teacher0/frame0/state未検証を明記、size成功は必要条件だけ。

workerはapply_patchのみ、compile/native/Git/外部/削除/追加委任0、固定rustfmt非書込syntaxとledger後READY/完全停止/hash/mtime返却。親全文レビュー後compile/native各1。packet worst142335*278+834bits＋4Bは原5MiB以下、node MAX_BITS142335/MAX_BYTES17792を維持。原global段階のmodel32MiB/phase64MiB、BWT・OS WS/private各160MiBを維持（前temporalの24/48をglobalへ誤適用しない）。source+PLAN+FAILURE300KiB、EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、未使用build/khc-global-minor-codebook-20261005にEXE/report2files/8MiB、空き5GiB。fixedruntime/opt3/thin/CGU1/unwind/overflowyes/debug0、60/120秒、原bounded helper/pinsを使う。

基礎旧global readonly115組/3files/494389B no-goは親開始成功。終了にも同じ基礎検証を行い、実frame・teacher実更新・速度・holdout/4nativeを元完了条件へすり替えない。
