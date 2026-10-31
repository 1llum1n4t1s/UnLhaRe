# branch-history MDL：一設定size-first・コード前契約

QUESTIONのtrained静的分岐履歴モデルを実装する。旧flat static、単一suffix KT、prior/係数調整、CTS局所高速化の再試行ではない。新branch-history-mdl/と未使用build/khc-branch-history-mdl-20261004/だけ。workerはgrammar/model/probe/runner/FAILURE_PLAN/RESULT/verifier、親はhappy/adversarialとこのplan/decision。旧root/source/reportはread-only、製品/wire/API/版/依存/Git/外部write/削除/x86/追加委任なし。

## 失敗条件（コード前）

class/node/prefix/child/historyの順序を誤る、prefix1のhistory更新を落とす、short inputのsentinel/合法limit誤り、未来token依存をmetadataへ保存しない、histogram親とchildren総数不一致、overflow、DPでheader費用を無料にする、CDF Hamiltonのtail/支持/total/同率順を誤る、serialize/parseのtag/15bit/深さ/長さ/paddingを誤る、parsed dispatchとの全CDF/全loss不一致、割当て/実peak/出力/time超過、loss screenを実frame/速度/総合勝利へ読み替える。

## 固定方式とprivate helper API

quaternary Treeは既存lookup-float-cts/model.rsのTree buildを同じ定義で使用し、class getterだけ追加可能。class6、合法prefix1..4、CTS同様各class初期history0、child観測後history=(history<<2)|child、参照時last10bit/深さ0..5。prefix1もchild0で履歴を更新するがhist/Q符号費用は0。2..4は18groupsで、各1365nodes×4u32 raw histogram。node indexのpathは4*id+1+digit、digit=(history>>(2*level))&3。

Hist::new()->Result<Hist>、pub counts:Vec<[u32;4]>（18*1365）。record(class,k,history:u16,child)->Result<()>はclass<6/k2..4/child<kを検査して全6pathをchecked更新前確認し、拒否前後全counts不変。historyはu16値を受け、意味に使うlast10bitを保持する。

quantize([u32;4],k)->Result<[u16;4]>：k2..4、tailcounts0、raw total<=3825340。全count0ならuniform Hamilton。合法childにmin2を先に確保、残32768-2kをcount比例のinteger floor、largest remainderは降順＋index昇順、合計32768/tail0。CDF metadataは前k-1frequencyを各15bit保存、最後は32768-sumから復元。頻度各>=2、tail0。prefix1は暗黙frequency32768でu16に格納しない。

Fit::build(&Hist)->Result<Fit>、Fit::lookup(class,k,history)->Result<[u16;4]>。深さ5leaf、leaf費用=quantizedloss+1tagbit+15*(k-1)、split費用=1tagbit+4children最適費用。完全tieはleaf。hist親/children（depth<5）は各child countの全比較で一致。空nodeはuniform leaf、空groupもroot leafとCDF保存費用を払う。fit後はcountsをdecodeに使わず、全履歴/合法prefixを参照できる。

Fit::serialize()->Result<(Vec<u8>,usize)>、parse(bytes,bits)->Result<Dispatch>、Dispatch::lookup同署名。18rootをclass順/prefix2,3,4順、preorder、MSB-first tag0leaf/1split、split children0..3、15bit fieldsもMSB-first。実bytes=ceil(bits/8)、padding0、exact bit length/bytes/trailingを検査、depth5でsplit拒否、parse後全18*1024CDFのfit lookupと直接比較する。dispatchは18432*[u16;4]で147456B。

## 親の先行検証

正常：quant空k2/3/4、single[7,0,0,0]k4、tied[1,1,1,0]k3。k3期待[10923,10923,10922,0]。空Histは18root leaf/558bits/70bytes。class0,k2,h0 child0のみ100更新もleafのまま。h0 child0/h1 child1各10000ならclass0,k2 rootだけsplit、607bits/76bytes、h0/h1各pure frequency32766/2、h2/3uniform。serialize/parseは全18432CDF一致。

異常：k0/1/5、nonzero tail、rawtotal CAP超過、record class6/k1/k5/child>=kの拒否で全counts不変。empty packet、bits-1、extra byte、padding bit1、全部0のfirstCDFを拒否。深さ超過はraw split-only bytesを与えてbounded拒否。新unitなし、診断入口からhappy/adversarial二fileを呼ぶ。

## 固定入力、評価、資源

input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。一read/BWT、Front二walk（trainとparsed lookup loss）、tokens/runs889227各、escape742/history1778454/grammar58735a2b7383d755、branches[2725772,1099568]、class[889227,620240,1216305,889227,64372,145969]を照合。parsed CDFのKahan lossとDP選択leaf hist lossを比較し、headerbits+lossをwhole費用として照合。screen=ceil(branch_Qloss/8)+実headerbytes+3079、gate483599。failなら実coder/速度/精度/深さsweepへ進めない。

hist393120B、dispatch147456B、最大24570tags+18*1024*45freqbits=854010bits（106752B）という保守上限。DP/fit/parseを含むmodel作業は8MiBまでとし、front/runs/input/余裕を含むphase32MiBを上限として実capacity/size_ofを照合。BWT別phase推定141598926B、実peak160MiBまで。配列shape/ピークを実測と推定に分ける。

source300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB/全出力8MiB/空き5GiB、compile60s/native120s、rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/cfg frame_audit+primitive_audit。source全停止ready後に親が一compile/native、worker実行0。model-header.binは実serializeの証拠として106752B以内で保持、input/frame/plain/rawtrace/Cargo/PDB複製なし。親が事後readonly一回照合、process0、編集停止/ownership返却で凍結。総合goalは全速度/完成書庫/API/holdout/category/4nativeまで未達/active。
