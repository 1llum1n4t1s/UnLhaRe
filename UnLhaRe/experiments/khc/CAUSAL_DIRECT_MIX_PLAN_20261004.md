# 四feature causal direct算術混合：一設定診断

## 判断と範囲

静的directのwhole jointでもtoken推定512307Bでサイズ不通過。CTS/branch log-linearを残した微調整は数秒のまま。次はglobal/symbol/recent/jointの因果countをtoken単位で算術混合する新privateモデルを一設定だけ診断する。時間適応の利益は仮説であり採用ではない。旧単一direct prior調整/静的familyを再試行せず、設定sweepなし。製品・公開wire・Git・依存・版・外部書込み・削除なし。

## コードより先の失敗条件

future countsの混入、history更新順・rank/length/context/terminal/escapeずれ、hash aliasをexact modelと呼ぶ、prefix境界/overflow/rescale誤り、混合weightのfinite/正/和1違反、量子化CDFが非単調/zero freq/Q端点不一致、残存プロセス、input/source/tool pins変化、資源超過、entropy推定を実frame・復元・速度・汎化と呼ぶ、初回失敗上書き/有利な再試行。

## 固定モデル

- 凍結direct-feature-opportunity/features.rsの四key/history更新を読み取り再利用。Front.walkの同runs一回、token直前のcountだけを使い、length後にhistory更新する。rank limit=active、length limit=min(remaining,256)。257個のleaf domain（lengthの末尾unused含む）。
- globalはkeyを直接32rows、symbolはkeyを直接16384rows。recent/jointは各4096rowsに `h(k)=(k^(k>>16))*0x7feb352d; h=(h^(h>>15))*0x846ca68b; h=h^(h>>16)` wrapping u32、低12bit。component/contextもkey内でhashしaliasingを明記。四familyは同時liveで因果的に更新する。
- leaf u16初期1（KT半count）、観測tokenだけ+2。全257leaf合計に+2した値が32768以上となる観測前に全leafをceil(count/2)、Fenwickを再構築、その後+2する。rescale順を固定、u32 Fenwick、checked totals。初期prefixはleaf onesの和。
- 各expertの有効limit内totalで切ったprefix/countを確率へ変換。4weightはglobal key32contextsごとに初期1/4。混合CDF S(k)=sum(w_i*prefix_i(k)/total_i(limit))。Q=32768、`C(k)=k+floor((Q-limit)*S(k))`、C(0)=0、C(limit)=Qを厳密固定。actual intervalはC(token+1)-C(token)。正freqが保証される式だが浮動計算境界を実検査する。これはprefix normalization noteの単一CDF式とは別の新mixture量子化policy。
- 観測後expert likelihood p_i=count_i(token)/total_i(limit)、posterior=w_i*p_i/sum(w*p)。次weight=(255/256)*posterior+1/(256*4)。正finite、和1許容1e-12を確認。量子化freqではなくexpert確率でweight更新。exp/CTS/quaternary traverse/全257token毎回生成は使わない。損失log2は診断用のみ。leaf/fenwick更新は各family一回。
- rank/length別Kahan量子化loss、unquantized mixture loss、各expert loss、rescale/alias/row/capacity/prefix query/update operation countsを記録。actual token lossからceil(bits/8)+escape742+framing285+model-bitlength4+reserve2048（モデルtable保存0、policy metadataは未定）を保守screen値にする。483599B以下は次のwire/E2E設計の必要条件だけ。新coder/frame/decode/性能比較なし。

rescaleは予測に使った旧状態の後、observeの+2前だけに行う。f64混合とfloorのnative間一致は未検証で、portable wire policyの保証ではない。通過時にも四native/丸め規約と実coder全復元が別工程として必要。hashのmix関数は既存lookup-floatと同じでもfeaturekeyは異なるので旧expert再現とはしない。

## E2Eと容量

実装前に新root FAILURE_PLANを保存。手製history7runsは前診断と全event照合。Fenwickは独立dense-prefix oracleで初期/増加/32768直前rescale/全257/limit1/256/257を逐次比較。手製mixture CDFを全kで正freq・累積Q・actual intervalと独立scalar式比較、invalid token/limit/key/finite拒否も実行。新unit testsなし、bounded診断入口のみ。固定Front counts/grammar/escapeと全history更新を照合。

新 `causal-direct-mix/` と未使用 `build/khc-causal-direct-mix-20261004/` のみworker所有、親はplan/decision所有。leaf+Fenwick約38MiB（24608rows×(257×2+258×4)）＋run/input等、別BWT推定135.04MiB。実装前capacity含む最悪160MiB以内を再計算、peakは実測しない限り推定。rawtoken Vec/trace/frame/plain/input copy/Cargo target/PDBなし。source閉包300KiB、全出力8MiB、EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、compile60s/native120s、rustc opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE。一compile/native、失敗は保持して親へ返す。source/tool/input/凍結diagnostic/plan前後pins、report保存後readonly verifier/disk guard/process0、終了時ownership返却。

実行前親照合でworker draftのmix phase60000000B上限は算術不足と判明。実配列想定39577184B（leaf/tree/total/first-key/collision/bitmap/weights）、固定run12582912B、input2811006B、hist余裕1369112B、allocator余裕4194304Bの和は60534518B。モデル設定・固定160MiB契約は変えず、事前mix phase worstだけ64MiB=67108864Bに訂正する。compile/native前の訂正として担当へ通知、最終capacityから式を再検査する。これはpeak RAM実測ではない。

Performance/Normalizer/Hardening/Testerは因果性・区間式・資源・oracle照合を担当と親で確認。Modernizer/Cleaner/Intel/Async/Startupは製品/依存/外部/並行/起動を変更しないため非該当。再利用workerの自己確認と親確認であり別新context独立監査とは呼ばない。
