# 4分岐・構造文脈混合の機会診断: 実装前契約

## 根拠・反証条件

DIRECT_TOKEN_LOSS_RESULT_20261002.mdとloss report SHA B9C917798B1B335DC12F684AEBE32BC45D58C80E856F500859038702B0F56D5Bが示す通り、flat prior64はrankの損失を増やし、精度だけでは固定483599byteへ届かない。次はprefixの観測を共有する4分岐木とglobal/symbol/recent/joint文脈を組み合わせる。旧balanced codecの文脈は参考にするが、旧候補の性能を再試行しない。4分岐化や文脈混合が高速・高圧縮だとは事前に断定しない。

新sourceはquaternary-context/。まず圧縮wireを作らない機会診断として、同じ固定run/token列でprequential log lossとbranch件数を測る。projected entropy+escapeがfixed payload budgetに届かなければ、full frameや正式benchmarkへ進まない。届いても実frameサイズ/正確性/速度は未証明であり、整数化primitiveとfull契約が必要。

## 固定topologyとcausal文脈

元のnext-use rank/length/escape grammarと固定inputを維持する。rank token0..256、length token0..255を以下の固定範囲木で符号化する。
root: [0,1),[1,2),[2,4),[4,A)。
tail [4,A): [4,8),[8,16),[16,32),[32,A)。
tail [32,A): [32,64),[64,128),[128,256),[256,A)。
それ以外のwidth>1 bucketは4等分（width2は2個のleaf）で再帰分割。空区間はfull alphabet構築時に除外し、内部nodeはpreorderで安定IDを割り当てる。ID<256を構築時に確認。limit truncationは各nodeの後端だけを切り、合法childは常にprefix1..4となる。合法child1でも同じquery/update順を維持する。選んだchildの区間へ進みleaf tokenに到達する。原tokenを再構成する別のtree traversalとの全token/limit照合を実装前失敗計画に含める。

各nodeで4つのcategorical expert:
1. global: component(rank/length)×256+nodeの直列table（512rows）。
2. symbol: hash(nodeKey xor symbol*0x9e3779b9)&(2^18-1)。
3. recent: hash(nodeKey xor recent.rotate_left(11))&(2^18-1)。
4. joint: hash(nodeKey xor symbol*0x85ebca6b xor prevRankExponent<<24 xor prevLengthExponent<<16)&(2^18-1)。
nodeKeyはcomponentをbit31、node IDを下位へ置く。hashは旧codecのwrap乗算xor関数を使う。symbol/history/jointの3tableは各2^18rows、componentもkeyに含める。collisionは存在する仕様であり、無衝突とは主張しない。

counts4個を各1（half-count units）、total4で初期化し、observed childへ2加算。total32768へ達したら各countをceil-half。合法prefixのcount sumで条件付けしたexpert probabilityを使う。query前に4expertを取得、予測後に同じrowsを1回だけ更新する。

global nodeごとに4expert重みを1/4で初期化。mixed probability=sum_i(w_i*p_i)。observed child後、posterior_i=w_i*p_i/mixedProbability、w'_i=(1-1/1024)*posterior_i+1/(1024*4)。shareは1/1024固定、grid調整しない。この段階はf64の診断でありwireには使わない。zero/NaN/inf/重み和不一致を拒否する。

recentとpreviousはrun完了後だけ更新し、rank/length両方から同じ完了前stateを参照する。previous[symbol]=(exponent(rank.saturating_sub(1)),exponent(length-1))。recent=((recent<<4)|min(rank,3)|(lengthClass<<2))&0xffff。lengthClassは1/2/3..4/5以上の0/1/2/3。current symbolやrankをprediction中に見える条件と、次token以前に更新する状態を分ける。length predictionには既知のrankを反映するnodeKey設計を追加変更せず、今回jointは前回完了run情報だけとする。

## 照合・出力・容量

fixed all.group2811006byte SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を1回read/BWT、runs889227/ranklength各889227/escape742/primary1762795/alphabet257をfull proofへ照合する。
元run grammarのtoken digestもloss診断と同じkey/limit/tokenを別に集計して保持し、相違があれば比較無効とする（loss既存fingerprintはintervalを含むため、その値を直接流用しない）。
f64のprequential混合loss、expert別loss、rank/length枝件数、depth最大、rescale数、bounded state digestのみ保存。expert table/個々の確率/トレースをdiskへ保存しない。state配列はmemoryだけ。tree全token/limit逆変換、initial/rescale/invalid prefix、causal expert重み更新を独立計算と照合する計画をコード前に別文書へ書く。checksumだけで数値正確性を主張しない。

projected entropy+共通escape5936bitsを(483599-281-5)*8bitsへ比較するが、5byte flush予算だけでrange rounding誤差を保証したとは言わない。正式frame/速度gateではなく次段階を許可する機会判定だけ。rank/length ideal bitsをflat old bitsとも比較する。

fresh build/khc-quaternary-context-opportunity-20261002、8MiB予算、1opt2/overflowyes EXE+report512KiB、予想300KiB以下。compiler/runtime/source/import/corpus/proofをreadlock/pin/前後identity、child120s/stdoutstderr65536、debuginfo0 /DEBUG:NONE。Cargo/PDB/cache/frame/restore/rawtraceなし。existing root上書き/同条件retryなし。失敗は最小証拠と次の変更理由を保存する。source editsはapply_patch。

次のinteger wire形式はこの診断では未実装・未承認の成功判定。採用前には数値primitive、full E2E、固定frame gate、同境界encode/decode/CPU15%、holdout/カテゴリ、4native、製品/API統合が全て必要。goalは7-Zip総合超えのまま未達・active。Gitstage/commit/push/version/公開/外部書込/x86/共有cacheは対象外。

