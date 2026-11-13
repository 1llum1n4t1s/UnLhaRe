# block port SOURCE_MAP

2026-10-06 compiled-programのstatic geometry/CDFを製品へ仮統合。decodeだけprivate累積CDF（同Vec）と固定命令/prefix表を使い、encoder/公開wire/整数range/CRC/履歴を維持。旧CompactTree/decode_intervalは通常経路から除去し、旧参照はexperiments/khc/compiled-program/pre_port_grammar・pre_port_profileへ移した。prototype両順約52%短縮・全frame一致・finite532152/6979584CDF/684異常はSTATIC_RESULT_20261006.md参照。現製品Releasecheck/Clippy/実API・CLI正常2E2E成功、残7E2E/公開perf/native/未見は未検証、詳細PORT_PROGRESS_20261006.md。製品static宣言/直接参照/alphabet引数整理/診断fn除去を含むため凍結candidate source SHAと製品SHAは異なる。GOAL総合条件未達。

2026-10-06 KHS1BLK二成分range/root準備はsize+68Bで条件を通るが通常decode約12.8%遅化につき非採用。製品single state/wire/encoder/decoderは維持。49raw/全11旧-public frame一致と各成分2021327interval全byte再構成、254異常/4gap/8normalize切断の有限補完と保持資源はexperiments/khc/split-component/RESULT_20261006.md。元T1未達報告/通常速度reportを上書きせず、追加性能測定なし。本線full buildは今回未実行、新原理/総合優位ではない。

2026-10-06同class二枝合成の診断はgrammar明示枝7.079481%削減/理想loss-5.757bitで事前20%未達、候補coder/製品へ進めず不採用。66049幾何/32raw+全11 clone/public復元は診断scopeであり途中履歴/全Meta/独立encoded frame同一の証明ではない。製品code/wire不変、保持/再現/独立反証はexperiments/khc/compound-grammar/RESULT_20261006.md。次のrank/length状態分離研究は未実装。

2026-10-06除算なしCDF候補は全3161884契約/49raw/672異常/全11同frameでもdecode事前15%に届かず、lcet15.58%増で不採用。現multi_range/decode_interval/公開wire不変。両集計の厳密独立判定、frozen report初期timing flagの限界、保持資源と終端補完はexperiments/khc/divisionless-cdf/RESULT_20261006.md。追加製品full buildは行わず、従前E2Eと今回standalone検証を区別する。新原理・7-Zip総合優位ではない。

2026-10-06適応shadow LZ beamはfixed16で15.17%増、greedy終端でも0.720677%削減/kennedy8%悪化で両事前screen失格、不採用。33626 numeric/49raw/672decoder異常/全11自己cross/public復元、model shadow同期/境界/容量とcounter-only診断を実測。製品greedy/model/update/decoder/wire不変。失敗compile/監視race是正/8.82MiB中間清掃と保持証拠、case範囲/性能未測定はexperiments/khc/lz-beam/RESULT_20261006.md。新原理・7-Zip総合優位ではない。

2026-10-06 LZ費用選択の2別namespaceは48raw/672decoder異常/全11自己cross/public復元に成功したが、平均比は率悪化・同spanは全frame0.570875%削減で事前1%screen未達。現lz.rsのgreedyとwrite/read/update/decoder、公開wireを維持する。境界・整数log・proxy限界・非均等suffix oracle未網羅・資源/再現はexperiments/khc/lz-cost/RESULT_20261006.md。製品改善/新原理/7-Zip総合優位ではない。

2026-10-06 rANS別形式の有限E2Eと通常順実測で展開1.477%短縮/63B削減、事前15%条件へ届かず製品採用しない。現range/モデル/grammar/公開wire不変。跨filepackingも全復元するが固定順・ASCII90%二群ともsize条件を満たさず現entry独立を維持。結果と測定基盤修復/CPU timeout/清掃の限界はexperiments/khc/mdl-rans/{RESULT_20261006.md,SOLID_SIZE_RESULT_20261006.md}。新原理・7-Zip総合優位とは称さない。旧9E2E成功と製品同SHAを引き継ぎ、新候補finite/size診断と製品full buildは区別する。

2026-10-06のForest共有表を採用：packet.rsのReader/Packet prefixを維持し、各rootの1024CDF行が同じと全照合した場合だけdescriptorへ縮約、可変rootはoffset付きdense行として保持する。毎モデルのzero scratch初期化、high履歴反転、284モデルfinish、CDF/CRC/rangeとwireは不変。候補出典experiments/khc/forest-layout/compact_packet.rs SHA058D43FA627009D47C7E9F589558673AF19F80C1757E6D7DD6569F29668CDCA1、byte一致の旧対照dense_packet.rs SHA BA0BE650557F7F7224AA6632ECDD3BCB7023CF3DC4D69F0A293ADC33192EC618。境界6モデル5234688CDF/50拒否と既存9E2E、公開API両順320同frame/640self/64cross復元を確認。全可変保持6989848B＋parse追加4222622B。詳細・時間の小差とビルド来歴の限界・観測RAM・7-Zip未達はexperiments/khc/forest-layout/PUBLIC_RESULT_20261006.md参照。

2026-10-05のdecoder固定grammar表を採用：CompactTreeは元Treeを検査付きコピーし、固定142nodeのlo u16/next u8/class/countを片側2000Bで保持する（構築時の旧Treeは別）。padding/dynamic limit/lo256/terminal/履歴/CDF/CRCとwireを維持する。geometry34562合法文脈/172810edge＋39886拒否一致、両順計320同frame/640self＋64cross復元、既存9E2E/clippy/fmt成功。11実file展開中央値合計は初回7.01%/逆順6.86%短縮、encoderは不変で逆順1.45%増。純codec CPUや7Zip総合優位ではない。`experiments/khc/compact-grammar/RESULT_20261005.md`参照。

2026-10-05の固定token経路：grammar::Routesは製品Treeから256/257 tokenの最大8stepを構築し、walkの重複prefix/child探索とedge cloneを削減する。製品encoderはterminal通知を直接利用する。dynamic limit、k1含む履歴、Meta、形式/モデル、decoderアルゴリズムは不変。scratch予約は保守的に64KiB増。全合法66049組のgeometry照合、旧EXEと両順計320同frame/640self＋64cross byte一致、既存9E2Eを確認。11実file圧縮合計19.35〜21.18%短縮、展開合計0.64〜2.17%増を記録し、圧縮側の実装最適化として採用する。全入力改善/独自圧縮原理/7-Zip総合優位ではない。再現資料は`experiments/khc/token-routes/RESULT_20261005.md`。

全出典はUnLhaRe/experiments/khc/内のfrozen source。製品sourceはこれらへpath/importせず独立したblock moduleを使用する。既定wireの意図的変更0。親の同入力byte/真frame費用比較までは製品portの型/native/4環境が未検証。

| 製品file | 凍結出典 | 出典SHA256 | 明示diff／除外 |
| --- | --- | --- | --- |
| mod.rs | all-class-frame/codec.rs | 9D4C3DC21870D7E2C025FC8AFEFDEC44B35B3AE9BEF75C878A42E540B95E7091 | crate root importsをblock内modへ、bundle呼出しを内部へ。修理済み3 gate局所boundを維持。pub(crate) API。encode_mode(default false)とencode_low_history_only(true)を追加し低固定ではhigh Hist/Fit確保を省く。decode/wire演算変更0 |
| bwt.rs | causal-bayes-sais/bwt.rs | 810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F | SA-IS全アルゴリズムを保持。MAX_INPUTだけsuper::MAX_INPUT=1MiBへ狭める（既定frame上限と一致） |
| frontend.rs | static-direct-mdl/frontend.rs | 7B3BBFC66105A406F7526E74A0DBC904EA6D0E1D356A202F8B1AD57C80BFE558 | crate→super。histogram::Hist importとFront::hist分析関数を除外。run構築/next-use/walk保持 |
| histogram.rs | static-direct-mdl/histogram.rs | F4E8CC49AF4428E4C6984C9157B5FDF1C7E53771F57B2B63075727A23D4D6024 | exponentとlength_bucketだけ抽出。分析定数/Hist/record/done/validateを除外 |
| grammar.rs | node-history-information/grammar.rs | DE40FDB75D4AC97DF5E4E1F70BA2F6E6ED74309460C4B302B4E018808215A5AE | crate→super、frozen runner専用コメント更新。Tree/Meta/walk全保持 |
| counts.rs | node-history-information/counts.rs | 5693E16A94BEDB255F83219F54F634F1AD3D197985DA5FC5D7C9CAD172EB5E0F | Dense全文、演算差分0 |
| model.rs | root-history-order/model.rs | 46AA9A34A9E5DD7AA69D0C16929EF5AF5B671495B225F587DFE7F59CE4F39683 | 先頭のHist/量子化/LUT/compact/leaf_mode（旧leaf_bitsより前）とreverse_historyだけ抽出。未使用Hist::record/group/validate_lutを除外。旧Fit/legacy wire/旧parser/料金比較を除外 |
| bundle.rs | root-history-order/bundle.rs | F49C71CE4C49CD184AD3E9A18A3DE0F50B200F94605D6CC3C6309C7D14E95DDA | ingestだけ抽出、modelをsuperへ。旧834root packet/Reader/Forestを全除外 |
| paid_model.rs | paid-code-tree/model.rs | 5A310322C6B1AFA238FAD1CF5515D4C21B957F24A53099C995369DC396601FDC | crate→super。Repriced以降の旧tree再課金/baseline/minor集計を除外。loss_bits/selected_header_bits/selected_counts/selected_leaf_count/selected_split_count/node_size/serialize/mode_counts/selected_mode_counts/original_node_loss/original_selected_loss/root_split/root_high/root_order_bitsを除外。Selected::low_only追加。tree build/write_node/root APIs/Selected費用選択/Dispatch/parse維持 |
| codebook.rs | paid-code-tree/codebook.rs | 86C6655F5CA9BA64047B7D06570592C593E2427BBE3DEAF860534CCE8C92C9F7 | 未使用validate_fixed/nodes/header補助を除外（root文字列参照も除去）。257 lengths/fee/canonical encoder/table Decoder/writer/read_header維持 |
| packet.rs | all-class-static/packet.rs | C8C218C82F6F5C6AB7E17E6DCBD0EE703DDFE444FDA72A9FBEBC330384C81439 | crate→super。未使用ingest再exportとMAX_SERIALIZED_BYTES alias除外。全284model/852root実wire/Forest演算保持 |
| multi_range.rs | direct-token/multi_range.rs | CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129 | range_audit cfg audit_stateだけ除外。整数Encoder/Decoder演算維持 |
| packed.rs | packed-inverse/packed.rs | A6CD0CE6B8B82A40143A47A01279F66172635186001055714A02D17D63D87ACE | contract validateの同境界をローカル化しMAX_INPUT+1へ制限。reference-fallback branchを上限errorへ（有効1MiB入力では到達不能）。reference::filledをblock allocateへ。同visited23bit/LF/出力保持 |

## 境界と未達

2026-10-05のForest限定ValidatedCdf候補は不採用。全群parse保証とprivate constructor/k束縛を独立調査し、静的CDF再検査だけを型へ移した。9E2E/160同frame/320self/32crossは通ったが、初回process復号中央値合計は約1.55%増で改善せず、型候補のみ戻した。追加再現測定なし。戻した9E2E/clippy/fmtを確認。安全性の証明と速度効果は分離し、凍結候補EXE/reportを保持。`experiments/khc/validated-cdf/RESULT_20261005.md`参照。

2026-10-05のCDF選択・更新融合は不採用。CDF/slot/切断/終端検査を維持する候補で160同frame/320self/32crossと9E2E/clippy/fmtを確認したが、初回process中央値合計2.53%短縮は入力順とpair先行側を反転した再現で0.21%増となり再現せず、従来decode_interval＋consumeへ戻した。第三測定なし、wire/API不変、7-Zip優位ではない。凍結候補EXE/reportを保持。`experiments/khc/fused-decode/RESULT_20261005.md`参照。

2026-10-05の復号active列単一移動は不採用。通常process比較は160同frame・320self/32cross一致だが復号改善なし。追加880復号batchも完全一致したものの、公開APIと計測namespaceのコンパイル非対称性があり、速度改善の証拠にならない。active更新のみ旧二段shiftへ戻し、戻した本線の既存9E2Eを再実行した。候補EXEと結果は保持。`experiments/khc/active-rotation/RESULT_20261005.md`参照。

2026-10-05のnext-use前段：frontend::Front::walkは最大257件u16の次回使用順を保持し、先頭検査・二分探索rank・headの移動で従来の全symbol走査を置換する。追加scratch514B、rank/event/context/Meta/wire不変。凍結旧helperとの160同frame pair・320self復号・32cross復号、既存9E2Eと固定3block費用を確認。速度結果はzero-row除去と合算で、単独効果/7-Zip優位とは区別する。`experiments/khc/ordered-front/RESULT_20261005.md`を参照。

2026-10-05のzero-row ingest除去：`dense.row`のshape/tail/CAP検査後、活動class内のzero rowだけをencode呼出し側でスキップする。Histはゼロ初期化と検査付き非ゼロ加算で形成するため、counts・加算順序・選択CDF・wireは同じ。bundle内の任意Hist検査は残す。全11×4frame比較、双復号、既存9 E2Eと固定3block費用で確認した。工程計測・限定した効果・未達は`experiments/khc/mdl-phase/RESULT_20261005.md`を参照。

2026-10-05の明示revision 2経路：`lz.rs`は第一段階`examples/lhc_lz_probe.rs`（SHA256 4AAA6AB2E673523D4F7B093661988817626EDAFFA3726E914086401CAA745E48）のgreedy探索と整数適応モデルを移植。実験header32B/CLI/CRC/計測を除外し、製品の40B frame/CRCと共通rangeへ接続した。`HybridTrial`は全候補を実行、`BinaryAdaptive`は特徴走査を含む。既定revision 1は保持し、新method2/3はrevision 2に限定する。これは既存LZ原理の再実装・組合せであり、独自圧縮原理という主張はしない。結果は`experiments/khc/hybrid/RESULT_20261005.md`を参照。

2026-10-05の直接parse改善：packet::Reader::nextはnext_intoへ置換し、paid_model::parse_packet_node_intoで最終Forestのモデルsliceへ直接書き込む。parse_nodeはrootの1024行sliceを受ける。全検査と整数CDF/high履歴反転を維持し、284回の一時Dispatch確保と6979584 Bの再コピーを除去する。ローカルroot検証用Dispatchは保持、形式/APIは不変。旧新140同frame pair・28相互復号・既存E2Eと詳細計測はexperiments/khc/cpu-measurement-v2/DIRECT_PARSE_RESULT_20261005.mdを参照。これは独自圧縮原理ではなく既存方式の実装改善で、7-Zip優位の証明ではない。

親接続時の追加：Selected::root_lossは製品で参照0のため除外した（Fit::root_lossは費用選択に必要なので保持）。public wrapperからlow-only ablationを接続。wire演算変更なし。

独立レビュー後：parse_nodeの葉で全1024履歴をmask走査する方式を、同じ合同類pathをstep_by(4^depth)で列挙する方式へ変更。各CDF slot/順序は不変、全分割木rootあたりの割当は1024に制限。最大深さ5の全852 uniform rootを有効frameへ組み立てpublic decode E2Eで確認する。

親cargo check成功後のclippy等価style修正：primary>=raw+1をprimary>rawへ（rawは先に1MiB以下）、Stats.rawは同値initializer、Vecを持たないbook/range decoderのdropのみ除外（Vec decoder/Forestのdrop維持）。f/lengths/sumsのindex loopは同順enumerate/take/zipへ、if letと内側条件は短絡let-chainへ統合。bits%8!=0は!is_multiple_of(8)、LUT(j*base+23)/24は(j*base).div_ceil(24)へ（積は最大196608でoverflowなし）。判定順・加算順・wire byte・整数CDF不変の局所修正。gogoで各処方の反証条件を確認し採用。workerはcargo/clippy/nativeを再実行せず、親が再検証する。

本fileとFAILURE_PLANは新規記述。上の出典から必要な構造を移植し、明示した除外・namespace変換以外のwire変更を意図しない。paid_modelの未使用CAP再exportと削除済み分析関数のコメントも除外。全Rust13fileは固定rustfmtの非書込stdoutをapply_patchで適用し整形（演算変更なし）。Windows memory診断、experiment probe/E2E/report、teacher/pool、leaf-mode-choice、packed reference大規模fallback、旧LHA decoderはportしない。CRCは認証ではない。low-only ablationも同header/wire/decoderを使用し、既定選択を変更しない。閉じたblock以外のI/O/公開/path policyは親containerの責任。compile/native/Git操作はworker0、親E2Eがbyte-exact/拒否/回復/費用/RAMを実測する。

2026-10-06モデル費用の現source診断：PROFILE/pathのみを除く正規化で同一性を確認。16KiB整数逆表の単独ablationは全u16成功/拒否と旧新frame/cross復号が同じでも、両順の速度条件を満たさず製品へ移植しなかった。現floor_codeのpartition_pointと全数値/CDF検査を保持。根拠・不採用・次のlog2候補はexperiments/khc/model-cost/RESULT_20261006.mdを参照。この記録は形式/API/圧縮原理の変更でも7-Zip優位の証明でもない。

2026-10-06同log係数のOption再利用も、係数/leaf/Fit bitと全frame/拒否一致を確認しても両順の速度条件へ届かず移植しなかった。現在のuniform/quantize全経路を維持。zero-count量子化はsource呼出し数の約87%だが総時間比ではない。現式の維持、未採用と次の固定CDF再利用の仮説はexperiments/khc/model-cost/LOG_RESULT_20261006.mdを参照。

2026-10-06固定整数CDFも成功/Err21654件・全frame/cross復元一致でも速度両順条件不成立で移植しなかった。現quantize Hamilton実装と全検査は維持。次は実native全archive/solid比較の不足（3.135%サイズ削減は5%未達、単発decode時間は不利方向）からdecode費用切分けへ移る。小counterや単発時間を7-Zip総合優位にしない。詳細experiments/khc/model-cost/CDF_RESULT_20261006.md。公開APIの時刻復元は明示preserve_timestamps=trueで確認し、既定falseやwire/versionを変更しない。

2026-10-06実native decodeの9paired/逆順で約3.8倍遅い方向を確認。現子moduleへ接続したprofileを再compileし、全11frameのpublic/診断byte一致、8MDLでtoken/run83.15%・Forest3.13%を観測。古いphase EXEの割合を最新値へ流用しない。現range/Forest/model/packedと公開wireは不変、次の別研究形式で多値rANSを単独比較する失敗先行契約を保存。詳細experiments/khc/decode-phase/NATIVE_RESULT_20261006.md。まだ製品改善でも新原理でも総合目標達成でもない。
