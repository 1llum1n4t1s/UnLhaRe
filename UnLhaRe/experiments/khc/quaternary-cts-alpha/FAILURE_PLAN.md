# PERF-ALPHA failure plan (before code)

契約SHA256 C1D25F68A4A8CEC4CC3A1291E4944121486B8B3DF456B1AE5E9D434B8D9B6DBA。
新指定8filesだけ所有、旧source/契約/証拠/製品/x86/version/cache/Git/外部/追加委任を変更・実行しない。基点depth5/旧pool/旧Math、Alphaだけ。

## 固定失敗条件

- update入口invalid prefix→invalid kernel updateの短絡/leaf順を維持。next=[Q/2;LEVELS]、depth0は係数なしで旧空loop同値return。depth>0で旧denominator/alpha/retained式をcheckedで1回、after1..CAPにより新到達可能Errを作らない。旧posterior_switchレベル依存body/guard/Err順は係数行だけ引数化。u128/signed/unchecked/unsafeへの無許可差分なし。
- 新CTSは凍結depth全文のupdate reexport先だけ変更。旧q32 oracleは直接参照し編集なし。snapshot seal/fallback/current guard/CAP/prepare全完了後commit本文一致。
- 旧codec前段と同一、子codecはmid body/全14field Proof/CDF bits/timerを維持して新CTS aliasだけ変更、Math/pool旧。root call単位dispatch。
- kernel正常540=depth0..8×全prefix-child10×after1/CAP×weight0/Q2/Q。raw(l,j)=(l+3)*(j+5)、Kernel生成は旧predict_kernelのみ。旧new全Result配列/Err直接比較。
- kernel拒否329=入口225(after90/prefix27/child36/depth24/leaf48)+switch96(depth8/level0..7×6tamper×after2)+複合level8。switch tamper weightQ1/own0/ownQ1/raw0/ownmass-1/Qsquare1、複合level0/7・2/5でinvalid/denominator順を交換。合計869、拒否理由優先同値。
- depth0 class6×prefix4=24組、child全2周成功120。pure predict反復/公開Snapshot全field/node/history/observationsの直接比較とpredict後/observe後状態確認。各組6拒否=144(child/prefix0/stale/kernelkt改変/nodeCAP/classCAP)、旧新それぞれ拒否前後全state一致。小depth0state cloneだけ許可、frame cloneは禁止。
- frozen snapshot sealed392/223/22、depth[4..8]30/1070/90/pure5/constructor2/compact60、旧新selfcheck各70plain/70canonical/165malformed/20short/70model named/80assertions/CAP5維持。
- depth5旧新新旧ABBA1周、入力2811006/read1、frame478750/header285/payload478465/CRC433441561・3616798779・621578488/base0caac94407124a37/CDF3820763.985142052±1e-4/commongrammar/count/classes/nodes1365/storage196560を固定。Debug配列空白まで固定stats一致。全plain4/往復全Proof stats4/reference全Proof stats3/frame全byte3・1436250B。size<=483599全4/warmup0/外repeat0/inner timer0。
- firstA frame/proof/stats move保持/reference1枚478750B/live2枚957500B、codec timer外比較/current即drop/最終reference drop、峰実績encode直後guard前、counter失敗実績正確、全process peak未検証。
- unique148=codegen136+asm/report/result3+新8+契約1。codegenreport実fieldはsources_before/sources_after各136、statuspassed-codegen-only。旧Math130/Qcancel118/ABBA106/99/89/84/72/60/48全loops/hash/bytes/UTC/EXEguard維持、旧実行なし、冗長再保存だけscalar。graph17/18/root13/unique16、Rustfmt10、body許可置換/alias/validator未定義call0。
- fresh build/khc-quaternary-cts-alpha-20261003、8MiB/EXE1MiB/report512KiB/予約1572864B、5GiB+予算前後確認。child120s/stdout stderr64KiB/raw parsed保存後validator/kill dispose finally/最終EXEreport2件、nonExecute root未作成。input/frame/plain/temp/PDB/Cargo/traceなし。既存root/reparse/混在/超過停止。

## 観点・実行境界

実行前是正: 初回nonExecute構成はnew_cts=baseline/alpha_cts=candidateで148/graph17/18成功したが、frozen snapshot_comparisonがcrate::new_ctsへ接続してbaselineだけを再検証していた。補足契約SHA AC3A1B310D275885AF8BFAB2E2E19E9DE0368533A55AB470042F8EBFC880F69Cを追加。new_cts=candidate、baseline_cts=frozenを独立moduleとしoldcodecのCTSaliasだけbaselineへ、optimized/snapshot比較をnew_ctsへ、新depth0比較はbaseline/new独立対へ是正する。旧主契約は不変、149before/afterへ増やしcandidate Snapshot経路をguardする。compile/候補CLI/Execute0回。

opopのPerformance/Hardening/Tester成立根拠・観点台帳/採否は親と独立analystが所有。workerはAlpha意味保存/独立oracle/全field比較/資源寿命だけを実装。Modernizer/Normalizer依存や公開方式変更不要、Cleaner既存Proof再利用、Asyncframe/child解放、Startup/Intel非該当。PS parser/Rustfmt stdout/nonExecuteのみ、型/compile/CLI/Executeは親。正式速度/CPU/holdout/4native/製品統合/全process peak未検証。両方向平均短縮なら次研究候補、片方でも不合格なら旧基点保持/再測定なし。
