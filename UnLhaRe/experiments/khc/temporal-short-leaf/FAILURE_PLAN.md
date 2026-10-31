# Short leaf failure-first

親PLAN SHA256 ADECAFF3E410B9797C406F592B838B7B591FC64424C2AC82E9B5AAD8B14F8DDA。元paid-root6filesと証拠は不変。この文書保存後にコードを作る。

- 凍結temporal24拒否/65536・65537境界/Front3、既存packet正常4/拒否8/root3/weighted4を維持。packet case6はraw mode10を明示しminimum-frequency理由を直接確認する。
- 新pure9例（k2のdominant2、k3の3、k4の4）。独立canonical頻度、wire4/5/5bit、DP内部同bit、全1024history CDF、独立weighted lossを比較。
- 内部uniform1例（手製split+4uniform leaf=13bit）、raw3例（k2/3/4=18/33/48bit）、default root3例（DP0/oracle3/outer1bit）、DP leaf/split費用境界2例（空defaultとdepth5 split fixtureの実選択費用）を固定。
- 新wire拒否4例：mode11、k3 pure index3、truncated mode、truncated pure index。理由文字列と拒否後正常parseを確認。
- 全モデルのDP root内部bits合計＋852flags==実header有効bits。oracle root長とDP0を混同しない。原quantize/Hist/weighted/history/free集計を保持。
- 24MiB/48MiB/160MiBとpacket5053003B上限を維持。compile/native/追加委任/Git/外部/削除0、非書込syntaxと可逆ledgerだけでREADY後停止。

## 可逆変更ledger

比較元はtemporal-paid-rootの同名5rs。tile_accumulatorは全文同一。packetのweighted ingest全文同一。Hist/quantizeは短leaf helper marker前の全文同一。

paid_modelの差分は次だけ：`Node`定義前にleaf_mode/leaf_bits追加、build_node leaf bitsをdefault root0または新mode費用へ変更、selected_header_bitsでroot0をoracle3へ変換、write_node/parse_nodeのleaf部分を2bit modeへ変更、root_wireでobjective0をoracle3へ変換、末尾にroot_objective_bits/selected_mode_counts追加、説明comment変更。既存量子化・加算・DP比較式・lookup・履歴順は保持。全モデルserialize/selected_header_bitsはoracle wire長を指す。

packet差分はPaidStats追加field、root_default/objective照合、nondefault wire/objective照合、DP内部bitsとleaf mode counters加算、完成headerの内部bits+852flags一致検査。元record/weighted/CDF/bit連結/loss経路は保持。

e2e差分はmalformed case6にrawタグ10追加、元8拒否の理由照合、bits_wire/short_oracles追加、runへshort_leaf結果field追加。新pure9*1024=9216CDF、新内部uniform/raw/default/boundary parser全CDF=1024*(1+3+3+2)=9216。元packet全CDF3489792維持。新wire4拒否に理由・回復検査。

probe差分はkind/エラー識別/説明、新DP内部bits・outerflags・selected mode counters・tile実費field加算と照合。元freeQ/Meta/recordは保持。無料default rootを含むselected_uniform_leavesとpacket.default_rootsは異なる集計。

資源式は元paid-root維持。追加PaidStats4usize=32B*14=448BをAccumulator.capacity_bytesへ反映し、probe既存24MiB gateで実capacity判定。root oracle0→3の最大allocationは元MAX_BYTES内。packet上限・最多1packet/1node scratch・4MiB reserve・48/160MiBを維持。
