# 静的direct-tokenモデルの限定予算screen

## 根拠と対象

Release由来codegenでもFT1内部encode3265.241ms/decode3249.7542ms。重い枝予測を局所的に軽くする方向は総合到達の主経路として十分でない。凍結lookup-floatのBWT next-use grammarを保持し、rank/lengthを直接多値tokenとして扱い、offline静的CDFを保存する新private方式を設計する。既存online Fenwick/Dirichlet、suffix KT失敗の再試行ではない。公開API・製品wire・バージョンは変えない。

## 実装より先に固定する失敗条件

frontendのrank/limit/length/historyずれ、sentinel/終端rank0/active insertion/varint escape誤り、固定grammarとの全histogram不一致、空モデル/未使用symbol/単一symbol/32768量子化のゼロfreq・overflow・総和差、MDL親子選択でside-informationを無料扱い、model headerの切詰め・重複symbol・範囲外・不正freq・余剰非zero padding・不正tag、serialize/parse後の全CDF/dispatch差、量子化後の有限loss違反、limit内desired freq0、見積りを実圧縮サイズ/速度/roundtripと呼ぶ、input/tool/source pin差、timeout、生成物容量超過、raw trace/frame/plain/input copy、旧証拠上書き、有利なsweep/retry。

## 一候補のモデル契約

- rank全体257値、length token256値（length-1を255でclamp、255は既存uniform varint escape）。rank contextsはglobal→current BWT symbol257→previous rank per symbol min(3)の4区分。length contextsはglobal→exponent(rank+1)の9区分→previous length per symbol（初期/1,2,3-4,5以上）の4区分。histogram countsはu32、集計/積算checked。
- 使用symbolだけ正freq、総和32768。used個に1を割当て、残りを整数floor比例割当、残余はHamilton最大剰余・symbol index tieで配る。used=1は32768。学習入力に現れた全tokenを保証する。オンライン学習はない。
- rank/length global CDF必須。各257/9 groupに2bit tag（inherit、own leaf、inherit+4child、own+4child）。split childは各1bit inherit/own、own時だけCDF。空group/childはinheritをcanonicalとする。CDFはused count9bit、sorted symbol IDs9bit、最後以外freq15bit、最後freqは32768-sum。header byte paddingはzero。unconditional quantized loss+実header bitsを最小化し、tieはinherit/leaf優先。一階層だけ、depth/parameter sweepなし。
- 選択後、同じrunsを再走査しvalid limitでtruncated CDF cumulative[limit]を使って実tokenのnegative log2 likelihoodを集計。uniform escape bytesは8bit/byteとして別計上。実serializeしたmodel bytes+ceil(loss/8)+escape bytes+285B framing+4B model-bit-length+2048B coder reserveを保守的予算値とする。483599B以下でも候補資格のみ、実coderサイズ保証ではない。
- decoder lookup最大表見積り（32768*u16*選択CDF数）、histogram/work RAMとmodel bytesを記録。初期化を含む速度は未実測。rANS実装や性能主張はこのscreenには含めない。

## 検証と実行

新 `static-direct-mdl/` のみ編集。高速scannerの全histogramを凍結reference codecへ最小observerを付けた独立経路と直接比較する。observer instrumentationはtoken完了とrun_doneだけ、数値/順序を維持し、無計器referenceとの全frame/plain/typedProof14/stats同値も比較する。trace全件保存なし。正常の空/一文字/反復/all256/text/fixed入力と、header malformedを事前一覧にしたE2E入口を使う。新単体unit tests追加なし。scannerのsequence全体の普遍証明ではなく、比較した全histogram/復元/frameを区別する。

rustc単体opt3/thin/CGU1/unwind/overflowyes/debug0/frame_audit/primitive_audit、compile60s/native120s。新出力 `build/khc-static-direct-mdl-20261004` 未使用必須、全生成8MiB、EXE1MiB/report256KiB/source閉包300KiB/stdout64KiB/stderr16KiB。実行前後disk-budgetとsource/tool/input/plan pinsを照合し、最終report後の実容量・owned process0を確認。新Cargo target/PDB/生trace/copyなし、削除・Git・外部書込みなし。失敗した結果は保持し、未実行と失敗を区別する。

## 所有権・観点・判断

parentはplan/既存decisionと採否を所有。停止確認済みfloat_stage_profile_implへ新rootだけの実装/局所実行を再委任する。他者のdirty変更を戻さない。Performanceは仕事数/予算、Hardeningはheader拒否、Testerは全比較、Normalizerは保存形式のcanonical化を評価。Modernizer/Cleanerは依存/旧方式/製品整理なしのため非該当、Async/Startup/Intelはこのoffline private budget screenで並行/製品起動/外部coder仕様を扱わないため非該当。opopの採用条件は製品変更へ適用し、このscreenはユーザー許可済み新方式の研究設計検証であって製品採用ではない。

別新context独立照合はagent thread limitで未実施。親照合と自己検証を独立照合と呼ばない。budget超過ならこの一候補は不採用、余裕があれば別計画で実coderと全復元を検証する。静穏full CLI固定size/encode/decode/resource、holdout/category/完成書庫/4native/製品APIは別条件。GOALはactiveのまま。
