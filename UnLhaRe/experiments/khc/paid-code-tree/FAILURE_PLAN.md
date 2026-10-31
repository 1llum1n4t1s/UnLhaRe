# paid-code-tree failure-first

固定計画 SHA256 8DD5902777BD58A56B224C154C1006B1A1EF90A8D766605313A923AA65EED803 を全文確認。実装前に以下を固定する。製品・既存実験・公開API・version・依存・Git・外部・削除変更0、compile/nativeは親のみ各1。担当は新6filesのみ。

| 失敗 | RAM有限E2E/本入力で必要な観測 |
| --- | --- |
| 未知minor無料/ESC誤復元 | 全256直接往復、既知length/未知19bit、ESC終端/raw切断/既知の冗長ESC拒否、canonical同長symbol順 |
| tableが無料または壊れている | flag1/length4/table129全134B、decoderはwire tableから独立再構築。flag/長>11/最終nibble pad/Kraft過不足/ESC欠落/trie容量拒否 |
| mode/dominant/残余不正 | k2/3/4×uniform/pure/compact×全dominant、compact tag0/pure10/uniform11、dominant範囲/underflow/非largest/min2拒否 |
| 木の座標/深さ/料金不正 | shallow/deep/depth5/low-high order、root split2/internal split1/default内部0/outer834bit、追加料金でsplitからleafに戻る境界 |
| wire切断/付加/非zero pad | bitlength/byte一致、field/code/ESC raw切断、pad/trailing拒否、拒否後同process成功 |
| 新DPが旧木再課金より悪化 | 旧wire typed parse→CDF/費用照合、各node/root/globalで新目的<=旧low/high木再課金、旧19914bit/header2624Bを本入力でassert |
| loss/CDF/履歴変化の誤報 | 個別root CDF854016、完成Forest→再Fit CDF854016、新DP=parsed/replay loss、元全Meta/freeQ/root counts、token/header/ESCの増減を独立表示 |
| 資源超過 | fixed max11/全展開129026<=142338、各Vec capacity実費/model32MiB/phase64MiB/scratch65536、codecはJSON前drop、OS WS/private各160MiBは親native |

失敗時は原因付きErr。同process回復は有限E2E中に観測。全失敗条件をここに先行固定し、post-code unit追加0。read1/BWT1/walk2、Fit/repricing passを全件計上。packet/code列/CDFtrace/input/frame disk保存0。

## 可逆ledger

新規6filesの追加だけ。FAILURE_PLAN.mdを含む最終SHA/mtime/bytesはREADYで親へ渡す。撤回はこの6filesの追加差分を対象にするが、本担当は削除を実行しない。凍結ファイルは編集しない。

## probeの厳密逆ledger

基点 root-history-order/probe.rs SHA256 41C867BD080052D64278C2352FAEC0A90E9C5AA8639C2A514F55D3AAE78A732D。現在のpaid probeは194行（LF）。以下の行区間を**下から上**へ原文へ置換すると、基点の146行・全文20444文字へ完全一致する。0行の原文は追加行の撤回。オーケストレーターRAM上で全17hunkを逆適用し、元全文と文字単位の完全一致を確認した。ファイル撤回・削除は実行しない。

### 逆hunk 1: paid行 14 から 7 行 → 原文 3 行

```rust
mod model;
mod bundle;
mod e2e;
```

### 逆hunk 2: paid行 34 から 4 行 → 原文 1 行

```rust
    near(teacher,2286636.8077715)?;model::validate_lut()?;let e2e=e2e::run()?;
```

### 逆hunk 3: paid行 44 から 1 行 → 原文 1 行

```rust
    let mut nodes=[[Node::default();142];2];let mut data=bundle::Packet::new()?;
```

### 逆hunk 4: paid行 52 から 4 行 → 原文 0 行

```rust
```

### 逆hunk 5: paid行 58 から 2 行 → 原文 2 行

```rust
        let mut hist=model::Hist::new()?;let mut high_hist=model::Hist::new()?;let mut root=[[0u64;4];3];let mut count=0u64;let mut free_loss=Sum::default();
        for k in 2..=4{for h in 0..1024u16{let row=dense.row(c,node,k,h)?;bundle::ingest(&mut hist,k,h,row)?;weighted_rows+=1;bundle::ingest(&mut high_hist,k,model::reverse_history(h),row)?;high_weighted_rows+=1;let fq=model::quantize(row,k)?;
```

### 逆hunk 6: paid行 62 から 14 行 → 原文 3 行

```rust
        for k in 2..=4{if hist.counts[(k-2)*model::NODES].map(u64::from)!=root[k-2]{return Err("weighted root counts".into());}weighted_root_comparisons+=1;if high_hist.counts[(k-2)*model::NODES].map(u64::from)!=root[k-2]{return Err("weighted high root counts".into());}weighted_root_comparisons+=1;}
        let low_fit=model::Fit::build(&hist)?;let high_fit=model::Fit::build_high(&high_hist)?;
        let fit=model::Selected::new(&low_fit,&high_fit)?;let node_dp=fit.loss_bits()?;let old_q=fit.original_selected_loss(&hist,&high_hist)?;
```

### 逆hunk 7: paid行 77 から 1 行 → 原文 1 行

```rust
        for k in 2..=4{let(local,bits)=fit.root_wire(k)?;let parsed=model::parse_root(&local,bits,k)?;
```

### 逆hunk 8: paid行 105 から 10 行 → 原文 2 行

```rust
    if data.len()*8!=32+header_bits+padding_bits{return Err("global actual bytes/padding/u32".into());}
    let forest=bundle::Forest::parse(&data)?;
```

### 逆hunk 9: paid行 121 から 3 行 → 原文 3 行

```rust
        let mut hist=model::Hist::new()?;let mut high_hist=model::Hist::new()?;
        for k in 2..=4{for h in 0..1024u16{let row=dense.row(c,node,k,h)?;bundle::ingest(&mut hist,k,h,row)?;verification_weighted_rows+=1;bundle::ingest(&mut high_hist,k,model::reverse_history(h),row)?;verification_high_weighted_rows+=1;}}
        let low_fit=model::Fit::build(&hist)?;let high_fit=model::Fit::build_high(&high_hist)?;let fit=model::Selected::new(&low_fit,&high_fit)?;verification_fit_builds+=2;
```

### 逆hunk 10: paid行 141 から 8 行 → 原文 1 行

```rust
    let mut node_report=String::new();node_report.try_reserve_exact(35000).map_err(|_|"node report allocation")?;node_report.push('[');
```

### 逆hunk 11: paid行 157 から 1 行 → 原文 1 行

```rust
            if row.len()>160 || node_report.len()+row.len()+8>35000{return Err("node report preappend bound".into());}node_report.push_str(&row);
```

### 逆hunk 12: paid行 163 から 1 行 → 原文 1 行

```rust
    node_report.push(']');if node_report.len()>35000 || node_report.capacity()>35000{return Err("node report bound".into());}
```

### 逆hunk 13: paid行 169 から 1 行 → 原文 1 行

```rust
    let scratch=std::mem::size_of_val(&nodes)+std::mem::size_of_val(&tree_classes)+std::mem::size_of_val(&node_orders)+node_report.capacity()+4096;
```

### 逆hunk 14: paid行 173 から 1 行 → 原文 1 行

```rust
    if scratch>65536 || model_ram>33554432 || phase>67108864 || model::Fit::node_size()>32 || data.capacity()>bundle::MAX_BUNDLE_BYTES{return Err("global model/phase actual capacity".into());}
```

### 逆hunk 15: paid行 178 から 11 行 → 原文 2 行

```rust
    let training_fit_builds=2*model_count;let total_fit_builds=training_fit_builds+verification_fit_builds;
    println!("{{\"status\":\"passed\",\"kind\":\"root_history_order_cost_screen_only\",\"E2E\":{e2e},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":2,\"tokens\":{:?},\"runs\":889227,\"primary\":1762795,\"escape_bytes\":742,\"grammar\":{},\"history_checks_per_walk\":1778454,\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"whole_two_walk_Meta_equal\":true,\"coded_branches\":{whole_coded},\"implicit_prefix1_branches\":{implicit},\"selected_mask\":[2,5],\"selected_node_counts\":{selected_nodes:?},\"selected_coded_counts\":{selected_coded:?},\"minimum_actual_frequency\":{minimum},\"weighted_rows\":{weighted_rows},\"high_weighted_rows\":{high_weighted_rows},\"verification_weighted_rows\":{verification_weighted_rows},\"verification_high_weighted_rows\":{verification_high_weighted_rows},\"weighted_root_comparisons\":{weighted_root_comparisons},\"Fit_individual_parse_CDF_comparisons\":{fit_parse_cdfs},\"completed_Forest_Fit_CDF_comparisons\":{forest_cdfs},\"model_count\":{model_count},\"distinct_models\":{model_count},\"training_Fit_builds\":{training_fit_builds},\"verification_Fit_builds\":{verification_fit_builds},\"total_Fit_builds\":{total_fit_builds},\"global_root_count\":834,\"selected_low_roots\":{selected_low_roots},\"selected_high_roots\":{selected_high_roots},\"selected_split_roots\":{selected_split_roots},\"selected_low_split_roots\":{selected_low_split_roots},\"selected_high_split_roots\":{selected_high_split_roots},\"root_order_bits\":{selected_split_roots},\"leaf_root_order_bits\":0,\"default_root_order_bits\":0,\"nondefault_leaf_root_internal_bits\":{nondefault_leaf_root_bits},\"node_root_high_flags\":{node_orders:?},\"global_default_roots\":{default_roots},\"global_explicit_roots\":{},\"bundle_bytes\":{bundle_bytes},\"global_DP_internal_bits\":{sum_model_bits},\"root_outer_flag_bits\":834,\"header_effective_bits\":{header_bits},\"sum_oracle_wire_bits\":{oracle_bits},\"global_padding_bits\":{padding_bits},\"length_field_bytes\":4,\"concatenated_root_bits_directly_compared\":{root_bits_checked},\"selected_leaves\":{selected_leaves},\"selected_splits\":{selected_splits},\"selected_uniform_leaves\":{},\"selected_pure_leaves\":{},\"selected_compact_leaves\":{},\"node_columns\":[\"coded\",\"objective_bits\",\"oracle_wire_bits\",\"DP_bits\",\"parsed_bits\",\"free_bits\",\"original_Q_same_selected_tree_bits\",\"approx_delta_bits\"],\"nodes\":{node_report},\"node_report_utf8_bytes\":{},\"DP_component_loss_bits\":{:?},\"parsed_component_loss_bits\":{:?},\"parsed_class_loss_bits\":{:?},\"free_component_loss_bits\":{:?},\"same_selected_tree_original_Q_component_loss_bits\":{:?},\"approx_component_loss_delta_bits\":{component_delta:?},\"same_selected_tree_original_Q_loss_bits\":{same_tree_original:.17},\"approx_selected_loss_delta_bits\":{approximation_delta:.17},\"DP_selected_loss_bits\":{selected_dp:.17},\"parsed_selected_loss_bits\":{selected_loss:.17},\"teacher_nonselected_loss_bits\":{teacher:.17},\"combined_loss_bits\":{combined:.17},\"Q_token_bytes_ceil\":{token_bytes},\"side_bytes\":3079,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"dense_capacity_bytes\":{dense_bytes},\"Forest_capacity_bytes\":{forest_bytes},\"max_Hist_capacity_bytes\":{max_hist},\"max_high_Hist_capacity_bytes\":{max_high_hist},\"max_Fit_capacity_bytes\":{max_fit},\"max_high_Fit_capacity_bytes\":{max_high_fit},\"max_Dispatch_capacity_bytes\":{max_dispatch},\"max_packet_capacity_bytes\":{max_packet},\"bundle_capacity_bytes\":{bundle_capacity},\"scratch_capacity_bytes\":{scratch},\"LUT_bytes\":512,\"model_working_RAM_estimate_bytes\":{model_ram},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":33554432,\"fixed_phase_RAM_limit_bytes\":67108864,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"fit_node_size\":{},\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_private_commit_gate_passed\":{private_gate},\"peak_resource_gate_passed\":{peak_gate},\"Dense_instances_simultaneous\":1,\"Forest_instances_simultaneous\":1,\"packet_instances_simultaneous\":1,\"node_scratch_instances_simultaneous\":1,\"packet_files_saved\":0,\"teacher_models_executed\":0,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"parameter_sweeps\":0,\"trained_in_sample_only\":true,\"teacher_state_preservation_verified\":false,\"speed_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",
```

### 逆hunk 16: paid行 190 から 1 行 → 原文 1 行

```rust
        mode_counts[0],mode_counts[1],mode_counts[2],node_report.len(),dp.map(|v|v.value),component.map(|v|v.value),class_loss.map(|v|v.value),free.map(|v|v.value),original.map(|v|v.value),screen<=483599,model::Fit::node_size());Ok(())
```

### 逆hunk 17: paid行 192 から 3 行 → 原文 1 行

```rust
fn main(){if let Err(e)=execute(){eprintln!("root-history-order: {e}");std::process::exit(1);}}
```

## 変更と検証の対応

- codebook.rs: 固定257長/ESC19料金、sort encoder/count decoder、513node上限、134B headerと129nibble表。code/CDF列を保存しない。
- model.rs: Hist/Hamilton/LUT/floor/compact量子化は旧modelを参照。新Fitは実prefix/canonical feeをDP構築時に課金する。低/高選択は根の目的で決める。旧typed wireを再課金し、各訪問node/root/globalの目的・旧wireの全CDFと重み付きlossを直接比較する。
- bundle.rs: 原834順・outerflag固定、実table/payload writerとtableを読んだdecoder。Forestは元Dense/history座標と同じ。旧bundle::ingestを参照。
- e2e.rs: 先行固定した有限RAM E2E、未使用73canonical codeもzeroを直接確認、全257項目照合。全256往復と既知183/未知73、最大trie513、全mode/dominant、深さ/履歴/order/追加料金leaf境界、table/field/ESC/trailing/残余拒否と回復を実行する。paid Fit11/baseline Fit1、baseline root scan1/CDF1024（固定入力とは別）。
- probe.rs: 凍結namespaceの旧E2Eを維持し、別paid_E2E・本入力train/reprice/root parse/完成Forest reFit/replayを接続。固定入力Fit1668=paid training556+baseline556+paid verification556。旧root E2Eは41attempt（40成功・1期待拒否）、Density側は別namespace。input read1/BWT1/walk2、巨大codecはJSON前にdrop、保持table257と料金scalarのみ。

rustfmt固定実体 C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustfmt.exe SHA256 AC9D781249BFFABBB1BEDB691A5EA6F63A818C1DDA73DD698D4DFF687AD4C24E。--edition 2024 --emit stdout --config skip_children=true、stdout Out-Null。構文確認は型検査・native成功を意味しない。最終source SHA/mtime/bytesと最終非書込syntax結果はREADYに返す。compile/nativeは親のみ。

