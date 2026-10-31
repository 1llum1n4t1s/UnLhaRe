# exp scale：通常wire旧新pair

前turnは現codec profileと458878 finiteの実行証拠を取得したprogress。4native/正式速度/総合目標には未到達。現在finite readonlyを再確認exit0、追加compile/native0。次は同値Mathを実poolへ接続して全frameと普通の内部処理時間を比較する。計器やcustom allocatorをリンクしない。

## 固定接続

新root hard-cut-exp-scale-wire/。control_scopeは凍結hard-cut-model-lazy/codec.rsを直接参照。candidate_scopeは新candidate_codec.rs。候補codecは原通常codecからModel pathを`../hard-cut-model-lazy/lazy_model.rs`へ1箇所、root float_math/float_pool importをscaled_math/scaled_poolへ各1箇所だけ変更する。数値body/E2E/総timer境界は維持。

scaled_poolは凍結lookup-float-cts/float_pool.rsからMath importだけscaled_math::Mathへ1箇所変更。scaled_mathは成功済みhard-cut-exp-scale/scaled_math.rsを直接参照、複製・再変更なし。Modelはsuper固定aliasを通じて各pool/mathへ型接続する。CTS adapter/lazy_engine/old vector/BWT/coder/価格/元finite E2Eは凍結・直接参照。root float_math/float_poolは旧型のままcontrol向けに保持する。

codec3siteとpool1siteを復元すると原全文に一致することを実行前に確認する。同期の独立Model生成と破棄、全guard/error/commit順を維持。通常経路は計器/allocator/counter追加なし。

## コード前の失敗契約

source/tool/input/前証拠SHA不一致、graph外参照・allocator・cfg違い、接続復元差、compile/timeout/panic/保存失敗、全旧新frame差、全plain/typedProof/全stats/crossDebug差、CRC/header/magic/size差、case数・direction数違い、余分な再encode、reference frame/旧plain保持でphase予算超過、実メモリ/ディスク超過を失敗とする。FAILURE_PLANへ先行保存してからprobe/sourceを作る。新post-code unit testは書かない。

元selfcheck14正常/34破損/短depth4をcontrol/candidateそれぞれ専用processで1回。元e2eを変更せずtypedProof/全plain/再frameを維持し、stdout全文E2Eを前通常証拠と照合。旧whole Node状態seed拒否26を今回件数へ足さない。

fixed input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76をread1。control encode1→candidate encode1、全frame478856B直接比較。control decode1→candidate decode1でそれぞれ全plain、各同型Proof14 Eq、全stats一致と全14field crossDebugを確認。旧plainは候補decode前にdrop。最大2frame、decode途中に3frameを作らず、disk frame/plain/input0。旧新typedProofは別型なのでcross typedEqと誤記せず、各direction同型EqとcrossDebugを分ける。双方validate_fixedを行う。

同一pair実行内のencode/decode内部時間を報告するが、各1回/control先行/warm0のscreenであり正式速度や安定改善率ではない。有利な再試行・ABBA追加・parameter sweepなし。このcandidateは全同値とsource/資源に合格しても通常速度screenまでのprivate候補、製品/最終採用ではない。

## 資源と実行

親がrunner/verifier/PLAN/RESULT/log、同workerがFAILURE_PLAN/control_scope/candidate_scope/candidate_codec/scaled_pool/probeの6filesを所有する。旧source、finite/profile証拠、新Mathを編集しない。workerは非書込構文・全文接続照合まで、compile/native0で編集停止READYを返す。親レビュー後compile1、native selfcontrol1/selfcandidate1/pair1の3回。linkだけを生成し前ASM副作用を再発させない。

source＋plan<=300KiB、EXE<=1MiB/report<=256KiB、fresh build/khc-hard-cut-exp-scale-wire-20261004<=8MiB、空き5GiB。tool/input/source/runner/先行計画・証拠をbefore/after/liveでpin。失敗reportを保存、旧出力先を再利用して上書きしない。shell Math.Max等はdouble/long型を明示してInt32誤選択を避ける。

Model source推定21561264B<=32MiB、encoder（旧参照frame込み）45723494B、inverseはinput＋2実framecapacity＋14*2811007＋65536＋4194304、各phase<=64MiB。BWT phase source bound142647787B。Win各selfとpairのWS/privateは各160MiB以内を個別確認、source推定と実測を混同しない。typed stats/Proof等は余裕4MiBへ含め、base Vec private実capacityを実測したと言わない。

Modernizer依存変更なし、Normalizer静的型接続と全文allowlist、Performance finite命令差をnormalへ検証、Hardening/Tester先行全結果/元finite/CRC、Cleaner生copy0・前証拠保持、Asyncはframe/plain/Model phase寿命。Intel/製品Startup非該当。Git/version/API/product/x86/external/deletion0。GOAL active、全正式gateと完成書庫/holdout/4native/7-Zip総合条件を維持。
