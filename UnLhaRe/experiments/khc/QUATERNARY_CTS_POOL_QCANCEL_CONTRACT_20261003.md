# depth5 pool Q-cancel: 同一binary旧新ABBA契約

## 基点・目的・非目標

depth8/5 ABBAの結果からdepth5を私的研究の暫定基点とする。本段階はPERF-POOL-QCANCELだけを旧A/新B/B/Aの1周で比較し、出力・拒否・状態・wireを変えずにpoolの2回目Hamilton正規化を軽くする。正式size<=483599B、single-thread正式codec median<574.5624ms、machine CPU<=15%、holdout/categories、Windows/macOS x64/ARM64 native、製品/API統合の固定条件は変更しない。Canterburyは開発corpusでありholdoutではない。

凍結基点はdepth ABBA contract SHA5617F19FE3D9325E6D7737FB898A218F8350926AE521D751A1E370FAD7CAAABE、result 7704B/SHA21790F39833CE40B2035E0ACC15D196D722579B9FDF5550A81AD9D7CFA168107、report 390728B/SHAAE9A4E360507F7CE1A39E87AFE4194CBA8ADDB13ECE0582D0ABE76BF431B30EA、EXE 378368B/SHA0CA1ABB4F9B61E86B569C10B77CC80E1B268EC2A69F53464E1B3035F084DE689。静的次候補doc SHA43EB3DF77B6F10B429CAEAE01F5E56D9D87B5643DB132539FF07CAB11018C602。旧106件のbefore/after/liveとEXE、旧99/89/84/72/60/48 basisをすべて照合する。旧Execute・旧EXE再測定は行わない。

## 所有と差分

親は本契約、レビュー、Execute、結果を所有。worker-high一人は新quaternary-cts-pool-qcancel/の7件だけを所有する: FAILURE_PLAN.md、probe.rs、codec.rs、optimized_codec.rs、integer_pool.rs、comparison.rs、verify-pool.ps1。コードより先にFAILURE_PLANを書く。新候補へのテンプレートCopy-Itemは機械的再利用として許可し、その後はapply_patchで編集する。凍結source/report/EXE・製品/API/manifest/version・Git・x86・shared cache・外部書込みを変更しない。PERF-ALPHAやSnapshot縮小は混ぜない。

旧codec.rsはmid codecの数値・decode・guard・timer bodyをそのまま複製し、e2eのpathを凍結midへ向け、optimized_codec.rsを子moduleとして宣言するだけ。旧新とも凍結depth/model.rsとmid/e2e.rsを直接参照する。optimized_codec.rsも同じmid bodyを使い、integer_pool aliasのみ新poolへ向ける。親codec::Proofを子moduleから再exportし、子側Statsからのproof_newは旧Proof::newと同じ全field式を使う。子の重複Proof定義/implは置かず、既存run_profile/run_restoreのProof::new呼出だけproof_newへ変える。これらはtimerの外でありencode/decode timer bodyは一致を維持する。モデル内dyn/trait/条件dispatch、追加inner timer、unsafeは導入しない。rootでcall単位に旧新を選ぶ。

新poolは旧Prediction/Update/observeを再exportする。predictのguard順、features/scores/ln/exp、qの汎用normalize、pのvector/minimum/CDFは旧bodyと同じ。唯一の数値差分はp用mass/normalizeをexactなu64 helperへ置換すること。汎用normalize・CTS・seal・CAP・commitは凍結参照のまま。

## 算術の成立範囲

直前の正常なnormalizeが返すqだけを対象とし、k=1..4、active q=0..Q、inactive0、sum(q)=Q。D=4096*k、m[j]=4095*k*q[j]+Qでsum(m)=D*Q。旧商(m*Q)/(D*Q)=m/D、旧余りはQ*(m%D)で、余り順位と同率child昇順は不変。m<=16381Q<2^46、sum<=2^46。checked u64のmass/商/余り/assigned/residual/incrementを用い、sum/residual検査を保持する。helperを任意の不正入力向け汎用normalizeとして扱わない。qのactive0は正常なのでvector(q)を追加しない。

## コード前の失敗条件・E2E

同一binary compare-poolで20 q fixtureを旧汎用normalizeと新helperで全要素直接比較する。各kの全one-hot10件、k2..4の均等normalize3件、k2 [1,Q-1]・[2048,Q-2048]、k3 [2048,2048,Q-4096]、k4 [1,Q-1,0,0]・[1,1,Q-2,0]・[1,1,1,Q-3]・[2048,2048,2048,Q-6144]の7件。residual0..k-1、同率切断、q0/Q、inactive0を覆う。k3 residual0は各余り1 mod3のため非該当。

旧opportunity.rs:436-494のinterior4、edge96、専用4の入力と専用child選択を再利用し、104 Prediction全fieldと257 Update全fieldを旧新直接比較する。BigInt正負・uniform・rareを含み、rareのq[0]=0、factor0、gradient全0、next不変を維持。8既存拒否+4拒否順（不正prefix+CTS、不正weight+CTS、不正CTS+count、CTS sum不一致+count）でErr文字列一致と拒否後Prediction不変を確認する。

compare-snapshotは凍結mid comparisonのsealed392/223/22とdepth[4,5,6,7,8]の30/1070/90/pure5/constructor2/compact60を維持。selfcheckとselfcheck-newは同じ凍結mid e2eを旧新それぞれ走らせ、各70plain/70canonical/165malformed/20short/70model named/80assertions/CAP5を必須とする。Snapshot改変/stale/foreign/rebased、拒否順、全prepare後commit・拒否後全state一致を減らさない。

ABBAはすべてdepth5、旧/新/新/旧の4回だけ。入力2811006B、frame478750/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052±1e-4。共通runs889227/primary1762795/alphabet257/rank889227/length889227/escape742/branches[2725772,1099568]/grammar58735a2b7383d755/classes[889227,620240,1216305,889227,64372,145969]/nodes1365/class・CTSnode196560Bを固定する。旧新4回の全plain各2811006B、各encode/decodeの全Proof・stats・CDF bits、基準Aとの全Proof・statsを直接比較する。Proofの部分投影やJSONの丸めを直接比較の代用にしない。

最初の旧A frame/proof/statsをreference1件として保持し、後続3frameを全byte直接比較する（3回・1436250B）。最大reference1枚478750B、current1枚を含むlive2枚957500B。比較・保持・dropはcodec call timer外、clone/ディスクframeなし。これはframe buffer上限であり全process peakではない。入力attempt1/success1、encode/decode/plain/stats各4、size合格4、warmup0、ABBA1周、protocol外repeat0、inner timer0。実績counterを失敗経路でも正しく残す。byte/Proof/状態/固定値/size/順序相違で停止する。

## freeze・runner・容量・実行

旧ABBA runnerのguard/child/immutable checksを継承し、新7件+本契約+旧ABBA result/report/EXE3+静的候補doc1を追加してunique118件をpinする。compiled graphは16 unique sources/17 edges/root12/unique destinations15（旧新codecが同じmodel/e2eへ2重参照）。alias/import、旧bodyから許可置換だけで生成した旧新codec/pool、全Proof constructor、validator定義とcallの静的一致を確認する。

重複proofの保存量だけを削減してよい。各Immutable関数の全照合loop・hash/bytes/UTC ticks・旧source数/EXE guardは必ず実行し、冗長なidentity配列の再保存のみchecked_countなどのscalarへ置換する。現在118件before/afterの全identityと旧report/EXEのpinを残す。旧reportを変更しない。出力reserveを広げるために照合を削らない。

workerはPS parser、Rustfmt stdout（全new Rust+直接参照CTS/model/e2e/comparison）、nonExecuteまでで、compile/候補CLI/Executeをしない。親レビュー後、fresh build/khc-quaternary-cts-pool-qcancel-20261003へExecute1/compile1/compare-snapshot1/compare-pool1/selfcheck1/selfcheck-new1/ABBA1。rustc1.98.1/edition2024/frame_audit/primitive_audit/opt2/overflow yes/panic abort/debug0/DEBUG:NONEを維持。child120秒、stdout/stderr各64KiB、raw/parsed保存後validator、kill/dispose/finally、source/EXE前後guardを維持。失敗後の無制限retry・数字を良く見せる再測定はしない。

出力root8MiB、EXE1MiB/report512KiB、合計予約1572864B、空き5GiB+予算を事前・事後検査する。nonExecuteはrootを作らない。最終EXE/report2件のみ保持。input/frame/plain/temp/bak/PDB/Cargo target/traceをディスク生成しない。既存root/reparse/混在/容量超過は停止。用途済み一時物だけ清掃し、再現に必要な証拠・固定入力は保持する。

## 観点台帳と判定

Performanceはanalystが算術と反例を調べ、親が採否・実測を担当。Hardening/Testerは同analystのq0/完全field比較/拒否順候補を親が確認して本契約へ採用。Modernizer/Normalizerは親担当で依存や公開方式の変更不要、CleanerはparentProof共有と冗長なreportコピーだけを対象とし算術・guardを削らない。AsyncはRAM frameの保持/dropとchild終了/Disposeを親・workerが検証し、並列codecは非該当。Startupは私的probeで利用者起動を扱わず非該当、EXE容量guardだけ維持。Intelは外部の現在仕様に依存せず非該当。worker-highは複数moduleの型共有・凍結body・失敗記録が連動するため選択し、要求/実効roleはgpt-6.1-sol/high。analystはgpt-6.1-sol/medium、Git/外部操作なし。

完全一致に合格し、encode/decode両方向のABBA各2回平均が短ければ次研究の候補基点に採用できる。いずれか短くなければ保留する。1周の診断値を正式速度、統計的優位、7-Zip総合超え、全process peak、製品最終採用としない。固定gateを通すための残作業は未検証として保持し、goalをcompleteにしない。
