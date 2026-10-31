# Global minor failure-first

親PLAN SHA256 83087092363CEA9DE3F83A94779006CE5550E0FB0B755E143BF94525DAEC4D4B。元source/証拠不変。保存後に実装する。

- LUT256値を独立整数式で全比較（512B）、strict増加/端点2・16383。全頻度2..16383の16382値について独立linear floorと候補floorを比較。各LUT exact roundtrip256、tie3例。
- pure9例（各k各dominant）、compact9例（各k各dominant）、default3例、内部split1例、DP境界2例（空root0/oracle3とdepth5 split）を固定。独立wire bits3/4/5/12/21/29、独立CDF・weighted loss。global default834flags/109B、正常global2fixture/Forest全CDF1708032比較、選択node278。
- wire拒否8例：mode11、k3 index3、truncated mode、truncated index、truncated code、k3 badminor16383×2、k4 badminor16383×3、depth5超過。exact root拒否4（0bit/上限/余剰bit/nonzero padding）、Hist/weighted拒否7（prefix2/tail/CAP2/shape/parentchildren）。global拒否6（field短/zero/超過/切詰め/余剰/padding）。理由と拒否後正常復帰を確認。
- 旧density happy/adversarialは凍結直接参照。旧global93bit happyには新wireを合わせない。post-code unit追加なし。
- 原Hist/quantize/weighted保持。compact CDFでDP、同じ選択木の原Qlossを別算術集計し符号付きΔL。root内部DP0/oraclewire3、内部bits+834flags==global有効bits。Fit→個別root全CDFとroot連結bit直接比較、完成packet→Forest全CDF、Dense parsed rowloss/nodeDPを直接照合。grammar2walkでnode/component/class/whole再検証。
- teacher0/frame0/state未検証。reference teacher2286636.8077715のみ合算、無料値・元Meta参照は親確認。費用screen必要条件だけ。
- Dense1/Forest1/packet1/node scratch1、model32MiB/phase64MiB/WSprivate160MiB、max保守packet142335*278+834bits+4B、output2files8MiB。compile/native/追加委任/Git/外部/削除0、固定rustfmt非書込syntax/ledger後READY・停止。

## 可逆source ledger

model基点はtemporal-short-leaf/paid_model.rs。原Hist/quantize/Reader/Writer/Dispatchを保持。変更はLUT/validate_lut/floor_code/largest/compact_frequency追加、leaf_modeのmode2 dominant、leaf_bitsのcompact12/21/29、build_node原quantize直後のcompact変換、mode2 write_node/parse_nodeのindex8bit格子と残余検査、末尾original_selected_loss追加だけ。Nodeの型/size、rootdefault DP0/oracle3、数値加算/DP比較/history順は維持。原Qlossは同じ新DP選択木の葉を原quantizeで再算術し、Δはnew-old符号付き。

bundle基点はclass-selective-static-mdl/bundle.rs。ingest関数全文を保持し、それ以降の旧per-model長field/append/Reader/Forest.parseをglobal packet方式へ置換。Forest.lookup/capacityと選択grammarは同等。Packet.finishは同Vecへ4B長fieldと最後のpadding1回、根ごとのbit直接連結比較を保持。default rootを含むselected_uniform_leavesとglobal_default_rootsは別件数。

probe基点はclass-selective-static-mdl/probe.rs。module参照を維持、旧happy/adversarialをdensity直接参照の新e2eへ置換。File1/BWT1/train/replay grammar2/原free root集計/hist ingest/MetaEq/固定censusを保持。入口はargc6（screen input teacher free-rank free-length）、diskbundle引数・OpenOptions/Write・出力経路を除去。train278+verification再Fit278=556と、weighted854016+verification854016を別report（親が直接Forest/Fit比較の追加passを明示許可）。rootoracle→全CDF/packet→Forest→再Fit全CDF/Dense rowloss→実replayの順。元sourceとoldrawは変更しない。

node8列はcoded/objective_bits/oracle_wire_bits/DP_bits/parsed_bits/free_bits/original_Q_same_selected_tree_bits/approx_delta_bits。孤立oracle wire費用を実DP費用へ混ぜず、sum_oracle_wire_bits=global_DP_internal_bits+3*global_default_rootsを直接検査。全node/component/whole deltaの再加算、teacher0/frame0/state未検証を報告。

モデル資源式はDense13959192+Forest6979896+maxHist65544+maxFit131064+maxDispatch24600+maxroot17792+Vec24+globalpacket(4+ceil((142335*278+834)/8))+Vec24+scratch65088+4194304+LUT512。Packet実capacity・max各scratchを用い32MiBで検査。固定phaseはruns.capacity*12+plain.capacity+modelRAM+1369112+4194304、64MiB。node型80B*284+tree2272+reportcapacity36000+reserve4096=65088B<65536B。row160Bと総JSON36000Bをappend前に検査、末尾delimiter8Bを予約する。stdout64KiB/report256KiBは親実行上限でも検査。

有限ケースは先行censusのまま。LUT256 roundtripは元CDF固定点に加え実index/code wireのparse復元も確認。新通常model oracle9bitは旧93bitと非互換、global default109Bは旧4448Bと非互換。metadataファイル保存0。
