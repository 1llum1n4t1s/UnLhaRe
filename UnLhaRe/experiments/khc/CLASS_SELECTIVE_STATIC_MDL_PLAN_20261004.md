# class2/5限定：費用込みnode/history MDLのコード前契約

QUESTION SHA0897C892B0E317B269A937E4FA81E468CE7FD893EB634F4C03B7CE6271946E40。新private class-selective-static-mdl/、未使用build/khc-class-selective-static-mdl-20261004/のみ。製品/公開API/wire/version/deps/x86/Git/旧dirty/凍結root変更なし。mask2/5固定、設定sweepなし。今回は費用screen、軽いteacher更新や実codec/速度は実装しない。

## 先行失敗一覧

mask/class/node/prefix/historyのalias、重みを1件として数える、LSB/6階層順の変更、CAP/tail/加算overflow後の部分mutation、Hist親子総和不一致、原Hamilton/DP/serializer/parse数値残差、3groupに旧class5を渡す誤接続、個別padding/32bit長fieldを費用から落とす、bundle切断/余剰/bitlen/CDF/padding/深さ破損、Fit対parse対bundle全CDF差、branch二walk/loss/count漏れ、丸めstatsをexact値と呼ぶ、保存lossの混合を高速状態保持やframe証明と呼ぶ、RAM/capacity/peak/出力/timeout違反を列挙してから実装する。

## 最小Model/束契約

新model.rsはbranch-history-mdl/model.rs（SHA2C910AD33D5D2E13D15A449DF169F725864F7B917533FACDFC16A4AA043B204C）の全文からGROUPS18→3、MAX_BITS854010→142335、MAX_BYTES106752→17792、group guard class>=6→class!=0の4定数/guardだけ変更。class0は局所3groupラベル。Hamilton、raw-bit loss+bits DPの同点規則、15bit field/MSB tag、個別zero padding、parse/Dispatch/Hist::recordは原数値のまま。全文allowlistをrunnerで照合。Node実sizeof<=32、Fit4095nodes、Hist4095rows、Dispatch3072rows。

bundle.rsのprivate APIを固定：ingest(&mut model::Hist,k:usize,history:u16,row:[u32;4])->Result<()> はDense一rowの重みをclass0の対応kへ6階層LSB最新child順で足す。全shape/k/tail/CAP/checked_addと6階層の次状態を先に確認してからassignmentし、拒否時Hist全counts不変。append(&mut Vec<u8>,bytes:&[u8],bits:usize)->Result<()> はmodel::parseも使って合法性を確認した後、32bit LE bitlenと個別bytesを追加。bitlenや長さ/容量拒否時out全byte不変。bundle最大5MiB。Reader::new(&[u8])->Result<Self>、next(&mut self)->Result<(&[u8],usize)>、finish(&self)->Result<()> でfield切断/byte extent/終端を検査。

Forest::parse(&[u8])->Result<Self> は凍結grammar Treeのcomponent0/1・node昇順でclass2/5に該当する139+139=278modelを読む。全modelを改めてparseし3×1024CDFをglobal配列へコピー、終端余剰拒否。Forest::lookup(c,node,k,history)->Result<[u16;4]> は対象c/node/k/maskを検査しlast10bitを索引する。非選択node/k1は拒否。capacity_bytes()は全heap+inline。global rows=2*142*3*1024（非選択slotは未使用）。個別Hist/Fit/Dispatchを278組同時に保持しない。

親happy/adversarialを先行固定、worker編集禁止。正常は原Density helper、uniform3roots header93bits/bytes[64,0,42,171,85,86,64,0,128,1,0,0]/3leaves0split、history0child0/1child1各100のk2 weighted fixtureで142bits/6leaves1split、3072CDF全比較を2回。束はuniform modelを278個、各16Bで4448B、全854016 selected CDFを比較。拒否はweighted ingest k1/k5/tail/CAP/加重後CAP、append拒否時全bytes、模型のmin frequency/padding/truncation/trailing/bits0/over/depth、束の切断/余剰/bitlen0/不正CDF/paddingを有限入力で検査し、固定入力前にsnapshotを破棄。新unitは追加しない。

## 単一native

一read/BWT/Front二walk。固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、runs889227/primary1762795/escape742/history1778454/grammar58735a2b7383d755、branch/class/prefix/historyは凍結node-historyと全Meta一致。初回全coded Denseをtrain（原counts.rs使用、prefix1はhistoryだけ更新）。class2/5 node各について対応Denseのk2/3/4×1024rowをweighted Histへ集約、各root数が元row数と一致、Fit→serialize→parseの全3072CDFを実比較、appendして個別modelを破棄する。278件、bundle bytes=sum(4+ceil(node_bits/8))を直接照合し、Forestでbundle全体を再parse。全selected Fit/individual parse/Forest CDFを再照合する（Fitが破棄済みならrow順のCDF digestだけを実比較の代わりに使わず、individual parse対Forestを全比較し、先行Fit対individual parse実比較と区別する）。DP lossと第二walk parsed lossのcomponent/class/node全和を1e-6bitsで確認する。

費用はceil((既存teacher非選択class0/1/3/4 loss+今回選択class2/5 parsed loss)/8)+実bundle bytes+side3079。既存teacher class lossは成功report SHA AFC738A0949275414F6F08E3E53E92D54904FE2C99276267C223B59574442794から取得してbefore/after/live pin。nativeにそのf64をroundtrip decimalで渡す。無料class2/5 lossも旧reportと照合し、MDL剪定による変化/実費用を分ける。side3079には2048reserveが含まれ、実wire下界ではない。raw-bit DPはbyte padding込み最適解を保証しない。費用screen<=483599でのみ次の実codec候補を支持し、失敗でも不採用の証拠を保存する。teacher高速経路/共有hash count保持/残りclass CDF維持は未検証。速度、frame、holdout、portable、採用claimはfalse。

## 事前容量・実行

モデル最悪：Dense13959192+globalForest約6980KiB未満（byteでは約6979904、sizeofを実照合）+Hist65544+Fit131064+individual Dispatch24600+individual header17816+bundle5242904+allocator4194304+scratch65536、およそ30680864B<32MiB。実capacity全和で32MiBを確認、宣言quota保証ではない。固定phase run1048576*12+input2811006+model実容量+frontend1369112+別allocator4194304<64MiB、BWT別141598926B推定、実WS/private commit各160MiB。bundle上限4947288B（278*(4+17792)）<=5MiB。出力はEXE1MiB/report256KiB/header5MiBの3files、合計8MiB内。全row/event/frame/plain/inputのコピー、Cargo/PDB、tracesなし。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/frame_audit+primitive_audit、compile60/native120秒、source300KiB/streams64KiB16KiB/free5GiB。原source/tool/input/report/plan/親fixtures before/after/live pin、unusedoutput、WinAPI80B/cb80終端一回、API失敗はnull未測定。closure実件数を非実行graphから固定する。

親はPLAN/fixtures/採否/実行/decision。workerはFAILURE_PLAN/model/bundle/probe/runnerのみ、後段RESULT/verifierは追加許可後。全編集停止READY後親singlecompile/native、後段停止後親readonly verifier一度。旧証拠/dirtyを戻さない、delete/Git/外部write/追加委任なし。6基本観点は親、Asyncはphase/snapshot解放、Intel/Startup非該当。全速度/完成書庫/API/4native等のGOALは未達/active。
