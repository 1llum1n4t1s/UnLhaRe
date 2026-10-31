# depth5 pool Math位置計算u64: 単独候補の旧新ABBA契約

## 基点・所有・実行境界

PERF-POOL-QCANCELは正しさに合格したが両方向の平均短縮条件に合格せず未採用。本段階は従来depth5/旧poolを基点とするPERF-POOL-MATH-U64だけを旧/新/新/旧1周で比較する。Q-cancel、PERF-ALPHA、Snapshot縮小、近似計算を混ぜない。size<=483599B、正式single-thread codec median<574.5624ms、machine CPU<=15%、holdout/categories、4native、製品/API統合の固定条件を維持し、開発Canterburyをholdoutにしない。

前段result7356B/SHAA02C14586236DF165DBC0BCABE4B44C747904F079B5924906AD4EDD5A694C14F、report343353B/SHA9754D28B1A1B896CE3DE0D032718AEDAEBB6CCC37164A5653417C715762E38FC、EXE477696B/SHAFDF4307CE825B9105CFFBAFCA2D70C8FFDE6F5D2127FBF4EB68EA11B40A78653を凍結。前段118 before/after/liveとEXE、旧106/99/89/84/72/60/48の照合を継承し、旧Execute/EXEを繰り返さない。

親は本契約・レビュー・Execute・結果を所有。worker-high一人は新quaternary-cts-pool-math-u64/の8件（FAILURE_PLAN.md、probe.rs、codec.rs、optimized_codec.rs、fixed_math.rs、integer_pool.rs、comparison.rs、verify-math.ps1）だけを所有し、失敗計画をコードより先に書く。テンプレートCopy-Itemの機械再利用以外はapply_patchで編集。凍結source/証拠、製品/API/wire/version、Git、x86、shared cache、外部書込みは変更しない。

workerはPS parser/Rustfmt stdout10/nonExecuteのみ、型/compile/候補CLI/Executeをしない。親レビュー後にfresh build/khc-quaternary-cts-pool-math-u64-20261003でExecute1/compile1/compare-snapshot1/compare-math1/selfcheck1/selfcheck-new1/ABBA1。child120秒/stdout stderr各64KiB/rawとparsed保存後validator/kill/dispose/finally/sourceとEXE前後を維持。再測定で好都合な数値を選ばない。

## 許可する数値差分

対象は旧fixed_math.rs:46,59,61の位置計算だけ。旧domain guard、Err文字列・順序、Q48 grid table、丸め/切捨て、補間・符号付き計算、戻り値を保持する。新Math sourceは旧全文の機械コピーから次だけを置換する。

- ln_scaled: n=1..Q、scale=0/32のguardを最初に維持。exponent/baseは同じ。pos=(n-base)*4096はn=Qで0、最大(2^31-1)*4096=8796093018112<2^43。posとidx/remをchecked u64で計算し、既存補間のremをu128へ戻す。
- exp_neg: d=0..128Qのguardを最初に維持。mag=d*65536<=2^55、rem<LN2<2^48、position=rem*4096<=799144290325106688<2^60。mag/最初の商余り/position/grid idx rem2だけchecked u64へ縮小し、補間のrem2をu128へ戻す。
- difference*rem、difference*rem2、Q48 LUT構築、count table、最終補間、exponent term、scale、signed helpers等のu128/i128は保持する。checked積の失敗文字列は旧unsigned product overflow、0除算の到達不能guardも旧意味を維持する。EXP_CUTOFF早期分岐・domainより前のcutoffは追加しない。

これは低精度化ではない。compilerが既に同じ64bit loweringをしていれば実効利益はなく、追加checked処理の逆効果も反証候補である。Big-OはO(1)のまま、時間効果は未測定。外部仕様に依存せず、旧sampling比率を現在時間へ外挿しない。

## module・body・全Proof

旧codecは前段の旧codec（mid許可置換済み）をそのまま新scopeへ複製する。子optimizedは同じmid numerical/timer body、同じ凍結depth/model.rs・mid/e2e.rs・親codec::Proof共有と全field式のproof_newを使い、fixed_math aliasを新Math、integer_pool aliasを新poolへ向けるだけ。旧新のrun_profile/run_restore timer bodyと14field Proof/CDF to_bitsを維持し、rootでcall単位に選ぶ。hot-loop dyn/trait/分岐dispatch/inner timer/unsafeを追加しない。

新poolは旧Prediction/Update/observeを再exportし、旧predict全文のMath importだけ新Mathへ向ける。p正規化は旧汎用u128 normalizeのまま。features/scores/ln/exp/q/p/vector/minimum/CDF/guard順を変更しない。新Mathを同じfrozen modelのmodule-relative importへ接続する。旧CTS/seal/CAP/commitを直接参照し、入力specificなtuningをしない。

compiled graphは17 unique sources/18 edges/root13/unique destinations16。前段118に新8件+本契約1+前段result/report/EXE3を加えunique130。前段の7sourceはその旧pathでpinし、新sourceを別pathでpinする。exactな旧codec/子codec/全Proof/pool import-only/Math許可置換guardとvalidator定義・call/4 CLI dispatchの静的照合を必須とする。

## コード前の失敗条件・Math比較

同一binary compare-mathで旧Mathと新Mathを各1構築する。全l4097/e4097/counts32769の計40963entryを値として逐次直接比較し、件数とidentityだけを報告する。正常/異常methodケースは以下の固定集合を使い、全戻り値またはErr文字列を直接比較する。大きな生値列/trace/入力コピーを保存しない。

- ln n集合: {0,1,Q-1,Q,Q+1,u64::MAX}と、e=0..32の{2^e-1,2^e,2^e+1}をunique sortedで合流して97値。各scale{0,32,u32::MAX}で291ケース、正常188/Err103。
- ln_count: {0,1,2,32767,32768,32769,Q,u64::MAX}の8ケース、正常4/Err4。
- exp d集合: {i64::MIN,-1,0,1,EXP_CUTOFF-1,EXP_CUTOFF,EXP_CUTOFF+1,128Q,128Q+1,i64::MAX}、e=0..32のceil(e*LN2/65536)±1/0、e∈{0,1,31}・g=0..4096のceil((e*4096+g)*LN2/(4096*65536))±1/0をunique sortedで合流する。fixture生成の乗算/ceilはu128のexact演算で行い、36958ケース、正常36954/Err4。grid端/指数端/cutoff前後/領域外を覆う。

method合計37257ケース、正常37146/Err111を必須とする。親は独立したBigInteger fixture生成で97/291/8/36958/37257を確認済み。候補Mathの型/出力を確認したという意味ではない。各ケース後にMath table不変を毎回全件走査する過剰検証はしないが、method群終了後に旧新tableを再度全40963entry直接比較して状態不変を確認する。table比較は2回81926entryで、初回の全entry参照値は旧Mathそのもの（&selfで非更新）として保持する。

さらに旧opportunity.rs:436-494と同じinterior4/edge96/専用4を、旧Math+旧pool対新Math+新poolでprimary Prediction104・Update257全field比較する。専用child選択、BigInt正負/uniform q/rare q0のgoldenを維持。12拒否の理由/順序と拒否後Prediction12を保持し、primary104/postreject12/total116を分けて記録する。Q-cancel helperの20fixtureは本候補の対象外で、新Mathへ混ぜない。

compare-snapshotはfrozen mid sealed392/223/22とdepth[4..8]30/1070/90/pure5/constructor2/compact60。selfcheck旧新は同じfrozen mid E2Eの各70plain/70canonical/165malformed/20short/70model named/80assertions/CAP5。Snapshot改変/stale/foreign/rebased、CAP、拒否順、prepare-all-before-commit、拒否後全state不変を減らさない。

## 全入力ABBA・RAM・容量

全depth5の旧/新/新/旧を各encode/decode2回だけ。入力2811006B（1read）、frame478750/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052±1e-4、共通grammar/count/classesとnodes1365/class・CTSnode196560Bを前段から維持する。FIXED_STATSはDebug配列の空白まで凍結生成式に一致させる。全plain4回、各往復全Proof/stats4回、first Aとの全Proof/stats3回、frameの全byte3回1436250Bを直接比較し、丸めやhash-onlyへ代替しない。size合格4/warmup0/ABBA1/protocol外repeat0/inner timer0。

first A frame/Proof/statsをmove保持し、後続current即drop・最終reference drop。reference最大1枚478750B、live最大2枚957500B、cloneなし。峰実績はencode成功直後、固定guardより前に記録して失敗時も正確に残す。比較/drop/JSONはcodec timer外。全process peakは未測定として区別する。

output8MiB、EXE1MiB/report512KiB/予約1572864B、空き5GiB+予算を事前/事後チェックし、nonExecuteでrootを作らない。最終EXE/report2件のみ。input/frame/plain/temp/bak/PDB/Cargo target/traceのディスク生成禁止。旧basisの照合loop・hash/bytes/UTCticks/count/EXEを全実行し、冗長旧identity配列再保存だけscalarを継続。現在130 before/after全identityは保持し、既存root/reparse/混在/超過で停止する。証拠は保存し、一時物の不要分だけ清掃する。

## 観点・判定・未達条件

Performance/Hardening/Testerの静的範囲証明はpool_next_math_audit（analyst gpt-6.1-sol/medium）が担当し、親が現コード・呼出元・fixture集合へ接続した。Modernizer/Normalizerは依存/公開方式変更不要、Cleanerは親Proof共有と既存冗長report保存の整理だけでguardを削らない。Asyncはframe move/dropとchild寿命を検証、並列codecは非該当。Startupは私的probeで利用者起動を扱わず非該当、Intelも外部仕様照会なしで非該当。複数Math型/module/型共有/全field固定/実行証拠が連動するためworker-high（gpt-6.1-sol/high）を継続する。親は統合/実行/採否を担当する。

全一致に合格し、ABBA各2回平均がencode/decode両方向で短ければ次の私的研究基点へ選択可能。片方でも短くなければ未採用。1周の観測から正式速度・統計的優位・7-Zip総合超えを主張しない。正式速度/CPU/holdout/categories/4native/製品統合/全process peakは本段階では未検証、goalはactiveのままである。
