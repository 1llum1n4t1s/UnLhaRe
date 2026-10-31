# 現hard-cut：CTS / pool / 残りの段階計測

## 判断

前工程はModel3 lazy通常候補のcompile1/native2とreadonly149組成功というprogress。通常単回内部2114.141/1998.692msでは固定速度ゲート未達。現候補の主費用を計測して次の演算削減を選ぶ。旧CTSの割合や旧fresh opt2結果は流用しない。

codec枝scope＋Model4呼出への観測専用hookを採用。CTS開始/終了だけのwrapper案は、pool/coder/Model早期拒否でscopeを確実に閉じられず、別predictのSnapshotと対応付けられないので不採用。計測scopeをcodecが所有し、RAIIで全?帰路をabort/clearする。

## 固定設計

- component0/1 × prefix1..4の8層。各層1-based ordinal128/384/...（mod256==128）を事前固定する。全枝count、sample、commit/abortと4子のattempt/success/error、timer pair数を区別して照合。prefix1も通常通り更新する。
- 子は CTS predict / pool predict / pool observe / CTS observe。元呼出のResultをそのまま返し、診断faultで数値Errを上書きしない。branch inclusiveはprefix確定後からModel observe成功まで、?で失敗したbranchはabort。
- sampled CTS＝2子合計、sampled pool＝2子合計、sampled残り＝branch inclusive−4子。残りにはcoder/tree/Model guard/audit/計器費用等を含める。各層parent>=子和を必要条件とする。
- BWT/inverseとModel constructorは低頻度のwhole区間として実測。既存run_profile/run_decode全timer境界は保持する。branch外escape/framing/digest/CRCもあるのでwhole残余をsample生時間で差し引かない。
- 層別N/n推定は明示した診断値のみ。合計推定がwholeを越えたら不成立・負残余として記録し、0へ丸めず、正式速度や確定CPU割合へ換算しない。空clock-pair固定10000回をcodec外で一度測り、差し引かない。全branchのTLS/counter擾乱は校正で消せない。
- 数値関数・型・Snapshot・CDF・float演算順・guard・error・commit順を維持。private hook/cfgのみで製品/API変更なし。TLS借用を数値呼出やcallbackへ持ち越さない。panic時Dropも数値panic/Errを追加panicで上書きしない。

## コード前の失敗契約

identity/source closure/token allowlist差、invalid component/prefix、nested/unfinished/double commit、無効なreset/方向切替、範囲外/重複/順序違いstage、stage Result Err、predict後pool/coder/Model Err、timer/counter overflow、親子負残差、frame/plain/Proof不一致、容量超過、compile/panic/timeout/保存失敗を列挙して先行fixtureに固定する。内部counter/timeの故意seedは診断帳簿の有限oracleであり公開API入力の検証とは呼ばない。

有限正常14/破損34/短header4は凍結causal-hard-cut-wire/e2eをそのまま再利用、今回完了を実行前に宣言しない。追加のstandaloneE2Eはdisabled→enabled→disabledの同frame、prefix1正常（空input）、拒否後同process正常、encode/decode方向reset、範囲内scope終了の確認に限定する。旧83件を未実行で今回件数へ足さない。

実拒否recipe：LCG seed0x6d2b79f5、4096Bをdisabled encode。payloadを先頭5Bへ切り詰め、payload length/CRCとheader CRCを修復してenabled decode。期待Errはtruncated range stream、scope abort>=1、pendingなし。sample0ならclock実計測は主張しない。codec境界の拒否E2Eとして固定し、当該分岐を確認できなければ未検証として返す。同process次の空input正常decodeで復帰を確認する。

## 固定入力と比較

fixed input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76をread1。hook disabled encode1のframeをRAMで参照保持→enabled encode1/decode1。全frame478856Bを直接比較、全plain2811006B、同型Proof14 Eq、全statsと前通常report/Debug一致。disabled参照は独立実装oracleでなく、hook復元全文比較で同じ現数値bodyと示す。今回旧nativeで再encodeしない。最大2frame、参照frameは比較後drop、disk frame/plain/input/trace0。

## 所有と資源

新root hard-cut-stage-profile/。phase1 worker所有FAILURE_PLAN.md/profile.rs/profile_e2e.rsだけ。fixtureの失敗条件保存をprofileコードより先に行い、親READY/全停止の確認後phase2へ進む。phase2は同workerのcodec.rs/lazy_model.rs/float_scope.rs/probe.rs/run-native.ps1だけを追加所有。adapter/lazy_engine/pool/math/coder/BWT/原finite E2E/前結果は全凍結。親がPLAN/RESULT/decision/readonly verifierを所有する。

source＋plan<=300KiB、EXE<=1MiB、report<=256KiB、fresh build/khc-hard-cut-stage-profile-20261004<=8MiB/空き5GiB。compile1/native selfcheck1＋profile1、各timeout既定60/120秒、重複起動・再選別なし。model推定<=32MiB/phase<=64MiB/実WS・private各<=160MiB。計器state上限64KiBをsource boundへ明示、encoder同時旧frame保持1048861Bを加算、BWT同時保持も加算。事前事後guardはquota強制でない。

Modernizerは依存変更なし、Normalizerはscope/計器統一、Performanceは主費用未測定を解消、Hardening/Testerは先行finite/RAIIと実拒否復帰、Cleanerは生copyなし・既存証拠保持、Asyncはscope/TLS借用/phase寿命を確認。Intel/製品Startupは非該当。Git/version/API/x86/外部/削除0。全正式速度/holdout/完成書庫/API/4native/総合7-Zip目標を維持しGOAL active。
