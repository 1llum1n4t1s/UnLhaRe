# leaf-mode-choice failure-first

実装前にPLAN全文 SHA04B0E1E8910C2093AC290CB9A60414F8A4A7F397FBFA6B1610162562C1E5985E とAUDIT全文 SHA538D0A56C25D13D945EEF5382CD89EBD82D4AD152C5B80989179BC80374D9E58 を照合した。新4filesのみを所有する。

| 失敗条件 | 有限RAM E2E／本入力で必要な検証 |
| --- | --- |
| 新uniform/pureの観測損失が無料 | 全k・非uniformからuniform・非pureから全dominant pure、独立全候補lossと実wire料金 |
| 候補順／同点／compact／emptyが変質 | legacy先頭→uniform→pure0..k-1、strict<、同点legacy保持、compact保持、empty/default内部0 |
| root/inner/depth/order料金を誤る | root split2/internal1、uniform内部3/pure4または5/有料compact、low-high/depth5と凍結wirefixture |
| baselineの新旧CDFを混同 | 旧paid typed wire leafを旧compact(quantize(hist row))へ直接照合。各node/root/global no-worse、全旧CDFとweightedloss、本入力旧loss1540684.988783758/21256bit/2791B/478416token/484286screen |
| 新CDF差をfloor誤差と誤報 | legacy/new uniform/new pure別選択数・Hamiltonとの差を新CDF選択損失差として保存。新DP=parsed actual CDF=replay |
| wire拒否／同process回復を破る | 前paid E2Eを新Fitへ接続しtable/ESC/min2/残余/切断/pad/trailing全fixtureを再実行、旧root E2Eも維持 |
| 資源／件数を取りこぼす | Node32、最大6候補stack逐次、Vec増加0、fixed1668Fitとfinite別、834flags/134B、全CDF/Meta/freeQ/codec drop／model32MiB・phase64MiB・scratch65536 |

本入力read1/BWT1/walk2。source/report/EXEは凍結、rawpacket/input/frame/code/CDFtrace disk copy0。worker compile/native/Git/外部/削除/追加委任0。post-code unit追加0。固定rustfmt非書込syntaxのみ。厳密probe逆ledgerと4SHA/mtime/bytesを返したらREADY編集完全停止。型・native成功は親のみ確認する。

## 厳密probe逆ledger

基点 paid-code-tree/probe.rs SHA256 41C44342843C92E405FAFAA271EBAA1D35DFC29736B5D70D252AFCF62B43E9D9。新probeは210行LF。以下を**下から上**へ置換し、旧194行・全文27019文字への完全一致をRAM上で検査した。凍結ファイルへの書戻し・削除は実行していない。

### 逆hunk 1: 新行 17 から 2 行 → 原文 1 行

```rust
mod codebook;
```

### 逆hunk 2: 新行 20 から 3 行 → 原文 2 行

```rust
#[path="bundle.rs"] mod paid_bundle;
#[path="e2e.rs"] mod paid_e2e;
```

### 逆hunk 3: 新行 36 から 2 行 → 原文 1 行

```rust
    near(teacher,2286636.8077715)?;paid_model::validate_lut()?;let e2e=frozen_e2e::run()?;let paid_e2e=paid_e2e::run()?;
```

### 逆hunk 4: 新行 59 から 3 行 → 原文 0 行

```rust
```

### 逆hunk 5: 新行 69 から 2 行 → 原文 1 行

```rust
        let low_fit=paid_model::Fit::build(&hist)?;let high_fit=paid_model::Fit::build_high(&high_hist)?;
```

### 逆hunk 6: 新行 72 から 2 行 → 原文 2 行

```rust
        let old_low=model::Fit::build(&hist)?;let old_high=model::Fit::build_high(&high_hist)?;
        let old_selected=model::Selected::new(&old_low,&old_high)?;baseline_training_fit_builds+=2;
```

### 逆hunk 7: 新行 75 から 1 行 → 原文 1 行

```rust
        for k in 2..=4{let l=low_fit.reprice_old(&old_low,&hist,k)?;let h=high_fit.reprice_old(&old_high,&high_hist,k)?;
```

### 逆hunk 8: 新行 81 から 2 行 → 原文 0 行

```rust
```

### 逆hunk 9: 新行 119 から 2 行 → 原文 2 行

```rust
    near(baseline_loss.value,1542185.5497685405)?;
    if baseline_bits!=19914 || baseline_header_bytes!=2624 || baseline_minors!=2142 || baseline_escapes!=0
```

### 逆hunk 10: 新行 132 から 2 行 → 原文 1 行

```rust
        let low_fit=paid_model::Fit::build(&hist)?;let high_fit=paid_model::Fit::build_high(&high_hist)?;let fit=paid_model::Selected::new(&low_fit,&high_fit)?;verification_fit_builds+=2;
```

### 逆hunk 11: 新行 152 から 1 行 → 原文 1 行

```rust
    let codec_phase_scratch=std::mem::size_of_val(&nodes)+std::mem::size_of_val(&tree_classes)+std::mem::size_of_val(&node_orders)+8192;
```

### 逆hunk 12: 新行 179 から 1 行 → 原文 1 行

```rust
    let scratch=std::mem::size_of_val(&nodes)+std::mem::size_of_val(&tree_classes)+std::mem::size_of_val(&node_orders)+node_report.capacity()+std::mem::size_of_val(&book_lengths)+4096;
```

### 逆hunk 13: 新行 190 から 1 行 → 原文 1 行

```rust
    if baseline_token_bytes!=478603{return Err("baseline token bytes".into());}
```

### 逆hunk 14: 新行 192 から 1 行 → 原文 1 行

```rust
    if baseline_screen_bytes!=484306{return Err("baseline screen".into());}
```

### 逆hunk 15: 新行 194 から 1 行 → 原文 1 行

```rust
    let ESC_count_delta=selected_escapes as i64-baseline_escapes as i64;
```

### 逆hunk 16: 新行 197 から 7 行 → 原文 2 行

```rust
    print!("{{\"paid_E2E\":{paid_e2e},\"book_lengths\":{book_lengths:?},\"codec_flag_bytes\":1,\"length_table_bytes\":129,\"metadata_prefix_bytes\":134,\"header_entropy_encoder_implemented\":true,\"header_entropy_decoder_verified\":true,\"estimated_cost_only\":false,\"baseline_repriced_payload_bits\":{baseline_bits},\"baseline_repriced_header_bytes\":{baseline_header_bytes},\"baseline_selected_loss_bits\":{:.17},\"baseline_Q_token_bytes\":{baseline_token_bytes},\"baseline_screen_bytes\":{baseline_screen_bytes},\"baseline_minor_count\":{baseline_minors},\"baseline_ESC_count\":{baseline_escapes},\"baseline_repricing_passes\":556,\"baseline_repricing_root_scans\":{baseline_root_scans},\"baseline_repricing_CDF_comparisons\":{baseline_cdfs},\"baseline_node_objective_comparisons\":{baseline_node_comparisons},\"baseline_training_Fit_builds\":{baseline_training_fit_builds},\"paid_training_Fit_builds\":{training_fit_builds},\"paid_verification_Fit_builds\":{verification_fit_builds},\"selected_minor_known_count\":{selected_known},\"selected_ESC_count\":{selected_escapes},\"token_byte_delta_from_repriced_baseline\":{token_byte_delta},\"header_byte_delta_from_repriced_baseline\":{header_byte_delta},\"ESC_count_delta_from_repriced_baseline\":{ESC_count_delta},\"token_loss_delta_bits_from_repriced_baseline\":{token_loss_delta_bits:.17},\"header_payload_delta_bits_from_repriced_baseline\":{header_payload_delta_bits},\"objective_delta_bits_from_repriced_baseline\":{objective_delta_bits:.17},\"encoder_capacity_bytes\":{encoder_capacity},\"table_decoder_capacity_bytes\":{decoder_capacity},\"table_decoder_trie_nodes\":{decoder_nodes},\"codec_peak_capacity_bytes\":{codec_peak_capacity},\"max_baseline_Fit_capacity_bytes\":{baseline_max_fit},\"codec_phase_scratch_capacity_bytes\":{codec_phase_scratch},\"codec_peak_model_RAM_estimate_bytes\":{codec_model_ram},\"codec_peak_phase_RAM_estimate_bytes\":{codec_phase_ram},\"codec_dropped_before_report\":true,",baseline_loss.value);
    println!("\"status\":\"passed\",\"kind\":\"paid_code_tree_cost_screen_only\",\"E2E\":{e2e},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":2,\"tokens\":{:?},\"runs\":889227,\"primary\":1762795,\"escape_bytes\":742,\"grammar\":{},\"history_checks_per_walk\":1778454,\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"whole_two_walk_Meta_equal\":true,\"coded_branches\":{whole_coded},\"implicit_prefix1_branches\":{implicit},\"selected_mask\":[2,5],\"selected_node_counts\":{selected_nodes:?},\"selected_coded_counts\":{selected_coded:?},\"minimum_actual_frequency\":{minimum},\"weighted_rows\":{weighted_rows},\"high_weighted_rows\":{high_weighted_rows},\"verification_weighted_rows\":{verification_weighted_rows},\"verification_high_weighted_rows\":{verification_high_weighted_rows},\"weighted_root_comparisons\":{weighted_root_comparisons},\"Fit_individual_parse_CDF_comparisons\":{fit_parse_cdfs},\"completed_Forest_Fit_CDF_comparisons\":{forest_cdfs},\"model_count\":{model_count},\"distinct_models\":{model_count},\"training_Fit_builds\":{training_fit_builds},\"verification_Fit_builds\":{verification_fit_builds},\"total_Fit_builds\":{total_fit_builds},\"global_root_count\":834,\"selected_low_roots\":{selected_low_roots},\"selected_high_roots\":{selected_high_roots},\"selected_split_roots\":{selected_split_roots},\"selected_low_split_roots\":{selected_low_split_roots},\"selected_high_split_roots\":{selected_high_split_roots},\"root_order_bits\":{selected_split_roots},\"leaf_root_order_bits\":0,\"default_root_order_bits\":0,\"nondefault_leaf_root_internal_bits\":{nondefault_leaf_root_bits},\"node_root_high_flags\":{node_orders:?},\"global_default_roots\":{default_roots},\"global_explicit_roots\":{},\"bundle_bytes\":{bundle_bytes},\"global_DP_internal_bits\":{sum_model_bits},\"root_outer_flag_bits\":834,\"header_effective_bits\":{header_bits},\"sum_oracle_wire_bits\":{oracle_bits},\"global_padding_bits\":{padding_bits},\"length_field_bytes\":4,\"concatenated_root_bits_directly_compared\":{root_bits_checked},\"selected_leaves\":{selected_leaves},\"selected_splits\":{selected_splits},\"selected_uniform_leaves\":{},\"selected_pure_leaves\":{},\"selected_compact_leaves\":{},\"node_columns\":[\"coded\",\"objective_bits\",\"oracle_wire_bits\",\"DP_bits\",\"parsed_bits\",\"free_bits\",\"original_Q_same_selected_tree_bits\",\"approx_delta_bits\"],\"nodes\":{node_report},\"node_report_utf8_bytes\":{},\"DP_component_loss_bits\":{:?},\"parsed_component_loss_bits\":{:?},\"parsed_class_loss_bits\":{:?},\"free_component_loss_bits\":{:?},\"same_selected_tree_original_Q_component_loss_bits\":{:?},\"approx_component_loss_delta_bits\":{component_delta:?},\"same_selected_tree_original_Q_loss_bits\":{same_tree_original:.17},\"approx_selected_loss_delta_bits\":{approximation_delta:.17},\"DP_selected_loss_bits\":{selected_dp:.17},\"parsed_selected_loss_bits\":{selected_loss:.17},\"teacher_nonselected_loss_bits\":{teacher:.17},\"combined_loss_bits\":{combined:.17},\"Q_token_bytes_ceil\":{token_bytes},\"side_bytes\":3079,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"dense_capacity_bytes\":{dense_bytes},\"Forest_capacity_bytes\":{forest_bytes},\"max_Hist_capacity_bytes\":{max_hist},\"max_high_Hist_capacity_bytes\":{max_high_hist},\"max_Fit_capacity_bytes\":{max_fit},\"max_high_Fit_capacity_bytes\":{max_high_fit},\"max_Dispatch_capacity_bytes\":{max_dispatch},\"max_packet_capacity_bytes\":{max_packet},\"bundle_capacity_bytes\":{bundle_capacity},\"scratch_capacity_bytes\":{scratch},\"LUT_bytes\":512,\"model_working_RAM_estimate_bytes\":{model_ram},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":33554432,\"fixed_phase_RAM_limit_bytes\":67108864,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"fit_node_size\":{},\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_private_commit_gate_passed\":{private_gate},\"peak_resource_gate_passed\":{peak_gate},\"Dense_instances_simultaneous\":1,\"Forest_instances_simultaneous\":1,\"packet_instances_simultaneous\":1,\"node_scratch_instances_simultaneous\":1,\"packet_files_saved\":0,\"teacher_models_executed\":0,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"parameter_sweeps\":0,\"trained_in_sample_only\":true,\"teacher_state_preservation_verified\":false,\"speed_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",
```

### 逆hunk 17: 新行 207 から 1 行 → 原文 1 行

```rust
fn main(){if let Err(e)=execute(){eprintln!("paid-code-tree: {e}");std::process::exit(1);}}
```

### 逆hunk 18: 新行 210 から 1 行 → 原文 0 行

```rust
```

## 実装と容量の台帳

- 新modelは旧paid sourceを基点に、legacy/uniform/pure0..k-1を最大6候補でstack逐次選択する。strict<で旧CDFの同点を保持し、そのbest.loss+bitsへsplitを比較。Hist/Hamilton/LUT・wire・Node32/Vec/Forest容量不変。
- build_countedはSelfへfieldを追加せず、再帰で実counterを増加。各full Fitは20475候補（1365×(4+5+6)）を検査。fixed入力paid train556とverification556は各11384100、selected leaf候補再評価も別実counter。baseline previous paid556を含むfixed Fit1668。
- typed previous paid parserは旧wire/tableでminorを復号し、旧leafを旧compact(quantize(hist row))へ照合。new selected frequencyとの同一条件を撤回。元root reprice_oldも同様。各訪問node/root/global no-worse、直接CDFとdepth5 Hist重み付きloss、実fee/defaultを検査。
- 新leaf finiteはroot27/inner27、nonuniform→uniform3/nonpure→pure9/legacy15/empty3/pure tie9/compact3。paid full Fits27/baseline27、直接候補評価278/full候補552825、解析CDF27648/baseline27648、node比較実counter。凍結paid finiteは新Fitを使い、低高/depth5/table/ESC/残余/拒否/回復を再実行。旧root finiteは旧namespaceのまま保持。
- candidate stack追加は保守的512B算術推定。候補集計array3×usizeとdelta3×f64=48B、および新leaf finite Stringの実capacity+String24Bをscratchとcodec phaseへ加算。旧62197Bに追加して65536以内を実行時検査。候補配列はstack、Node field追加0、codecはJSON前drop。OS物理peakは親nativeのみ。
- reportのcandidate数/損失差は小配列3要素のみ。Hamiltonとの新CDF選択差を明記し、旧approx fieldを同値aliasとして説明。旧baselineは21256bit/2791B/478416token/484286screen/2312minor/ESC0/loss1540684.988783758をassert。nativeでサイズ達成するとは主張しない。

固定rustfmt実体 C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustfmt.exe。--edition 2024 --emit stdout --config skip_children=true、stdout Out-Null。最初のsyntaxで新e2e match末尾semicolon1箇所を検出しcommaへ修正した。最終非書込syntax結果と4SHA/mtime/bytesはREADYに返す。型/compile/nativeは未実施。外部/Git/削除/追加委任0、rawdiskcopy0。

