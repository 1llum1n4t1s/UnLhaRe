# Root history order failure-first

親PLAN SHA256 CA36830092FA3FF33523BAA2D94BE607FEE73DC272639E4FACA6D355C1EC0ED2。元global-minor source/report不変。保存後にコードを作る。

- Rの1024値を独立5digit反転と比較、全単射・R(R(h))=hを全1024確認。
- 最新依存/最古依存2fixture、両順各k2の全1024CDFを独立pure頻度・独立lossで比較。最新low18/high4438、最古low4438/high18の実bit費用を固定。全置換対応をparserでも直接確認。
- 同node prefix混合1fixture：k2最新依存low選択、k3最古依存high選択、k4最新依存low選択。全3*1024CDF、root順とbit/loss独立oracleを確認。leaf/default無課金3prefixとroot0/oracle3を確認。
- 追加order1bit DP境界1fixture：k2,h0=[8,0,0,0],h1=[0,8,0,0]、他0。旧費用split15+tiny<default loss16、新費用split16+tiny>16でrootdefaultへ戻る。Histはingestから生成。
- 新wire拒否2例：truncated order、high root depth5超過。理由を直接確認し同process正常回復。
- global-minor finite census（density2直接参照、LUT256/512B/floor16382/exact256/tie3/pure9/compact9/default3/internal split1/DP境界2/wire拒否8/exact4/weighted7/global6/global正常2/Forest1708032）を新split/order wireへ適合して維持。旧深さfeeは4438、内部uniform手製root13→14bit。追加fixtureをpost-codeで増やさない。
- fit train低278+高278=556、verify低278+高278=556、合計1112。low/high weighted train/verify各854016、rootcount低高1668、Fit/rootと完成Forest/再選択Fit各854016。原freeQはlow1回のみ。選択root/DP内部bits/outer834/実header/orderbit/同選択木原Qloss/符号付きΔを照合。
- Dense1/Forest1/packet1/node scratch1。低高Hist/Fitは各2個の容量を全計上。MAX_BITS142338/MAX_BYTES17793、globalworstを更新。32/64/160MiBとJSON36000/scratch65536を維持。
- compile/native/追加委任/Git/外部/削除0。apply_patchと固定rustfmt非書込syntax/可逆ledger後READY・完全停止。

## 可逆変更ledger

基点はglobal-minor-codebookの同名4rs。原source/reportは変更しない。

model: MAX_BITS/MAX_BYTESを142338/17793へ変更、Fitにhigh bool追加（Node型32Bは保持）、buildをbuild_orderとbuild_highへ分割、root深さ0 split費用を2bitへ変更、high lookupにR適用、root write split直後にorder bit、parse_nodeのroot splitでorder読み取りと完成CDFのR swapを追加。root leaf/defaultにはorder fieldなし。末尾にreverse_history/root_splitとSelected借用selectorを追加。Selectedはprefixごとloss+実DPbitsで比較して同値low、lookup/wire/counters/原same-selected-treeQlossを各選択Fitと対応Histから返す。Hist/quantize/LUT/compactCDF/weightedの数値は元全文保持。

bundle: append_root引数だけFit→Selectedへ置換。元ingest/packetbit連結/finish/Reader/Forest全ブロックは保持。MAX保守上限はmodel定数参照で追随。

probe: low/high HistとFitを学習と再検証で各1組ずつ構築。highのingestへRを適用、全rootcounts低高1668比較。freeQは元low rowの1回加算を保持。node8列・Meta2walkEq・replay・同選択木Qloss/符号付きΔを保持し、train556/verify556/all1112とweighted low/high train/verify各854016を別計数。選択root high flags852Bを記録し再検証で一致、reportでも独立集計可能。CDFtraceやFit forestは保持しない。

capacity: max_Hist/max_Fitは低高同時保持の合計、max_high_*は内数（重複加算しない）。Histは131088B合計、Fitは262144B合計（新Fit自己32B×2含む）。modelRAM=旧式のDense+Forest+max_Hist+max_Fit+maxDispatch+maxroot+globalpacket+scratch+4MiB+LUT512。selector/制御stackはscratch reserve4096内。node_orders852Bを明示加算し、親承認のJSONcapacity35000Bへ縮小。scratch=Node80*284+tree2272+orders852+35000+4096=64940B<65536B。row160B/末尾delimiter8Bの事前境界検査を維持。

e2e: 旧finite全censusを新order wireへ適合（内部uniform14bit/deep4438bit/root split depth破損にorder field、globalfixtureはSelectedを使用）。新root_order oracleはR1024、対称2*2*1024=4096CDF、prefix混合3072CDF＋同一混合global Forest854016CDF、leaf/default3、追加1bit境界1、wire拒否2。混合globalはk2low/k3high/k4low、内部費用278*(18+22+22)+834flagsを直接照合。新拒否はtruncated order/depth理由と正常復帰。既存元densityは凍結直接参照。

report kind=root_history_order_cost_screen_only、入口argc6維持。selected_low/high_roots合計834、selected_split_roots/root_order_bits一致、high rootはsplitのみ、leaf/default order費用0、nondefault_leaf_root_internal_bitsを別集計。sum_oracle_wire_bits=global_DP_internal_bits+3*default_roots維持。teacher0/frame0/state未検証/in-sample・adoptionfalseを維持。
