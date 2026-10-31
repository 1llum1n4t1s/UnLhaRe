# PERF-POOL-QCANCEL failure plan (before code)

契約 SHA256: 06A85DD8249773BA8E1875122E4720DA8318B3C5FD1BB761F7D7DEE36289F8BA。
所有はこのディレクトリの指定7件のみ。旧source・証拠・製品・x86・version・cache・Git・外部書込みは変更しない。

## 固定する失敗条件

- 直前の正常normalizeのqのみを受けるu64 helper。k=1..4、active q<=Q、inactive0、sumQをchecked演算で確認。q0は正常でvector(q)禁止。m=4095*k*q+Q、D=4096*k、sum(m)=D*Q、商m/D・余りm%D・child昇順tie、assigned/residual/incrementを検査する。旧汎用normalizeとの全4要素不一致は停止。
- fixture20: one-hot10、均等3、境界7。residual0..k-1、tie、q0/Q、inactive0を包含（k3 residual0非該当）。Prediction104、Update257を旧新全field Eq比較。interior4・edge96・専用4の入力と専用childを旧opportunityから維持。rare q0/factor0/全gradient0/next不変を直接assert。拒否12（旧8+優先順4）はErr文字列一致と拒否後Prediction全field不変。
- compare-snapshotは凍結mid: sealed392/223/22、depth[4..8]成功30/拒否1070/failed90/pure5/constructor2/compact60を必須とする。
- selfcheck旧新各1回、同じ凍結mid E2E: plain70/canonical70/malformed165/short20/model named70/assertions80/CAP5。拒否順・全state不変の検証を減らさない。
- ABBAはdepth5旧/新/新/旧4回のみ。入力2811006、frame478750/header285/payload478465、plainCRC433441561/payloadCRC3616798779/headerCRC621578488、base0caac94407124a37、CDF3820763.985142052±1e-4、runs889227/primary1762795/alphabet257/rank889227/length889227/escape742/branches[2725772,1099568]/grammar58735a2b7383d755/classes[889227,620240,1216305,889227,64372,145969]/nodes1365/storage196560を固定。旧新各encode/decode全Proof・stats・CDF bits、全plain、first Aへの全Proof・statsが不一致なら停止。
- first A frame/Proof/statsだけreferenceとしてmove保持。後続3frame全byte直接比較、3回1436250B。reference1枚478750B/live2枚957500B、clone/ディスクframeなし。codec timer外で比較/drop。上限はframe bufferのみで全process peakではない。実績counterは呼出前/比較成功後で加算し失敗時も正確に残す。size<=483599全4必須。warmup0/ABBA1/protocol外repeat0/inner timer0。
- codec旧bodyはmidからe2e pathと子module宣言だけ。子codecはpool alias/e2e path/親Proof再export/free proof_new/2呼出だけ置換。Proof全field constructor式・timer body・旧Prediction/Update/observeを保持。guard順・features/scores/ln/exp/q汎用normalize/p vector/minimum/CDF変更禁止。
- runner118 unique identity、graph16sources/17edges/root12/unique15を固定。旧106/99/89/84/72/60/48 before/after/live/hash/bytes/UTC/EXE guard維持。旧Executeなし。冗長旧identity配列の保存だけscalar化してreport512KiB維持。validator定義と呼出も静的照合。
- fresh output build/khc-quaternary-cts-pool-qcancel-20261003、8MiB/EXE1MiB/report512KiB/reservation1572864B、空き5GiB+budgetを前後検査。nonExecuteはrootを作らない。child120s/stdout stderr各64KiB、raw/parsed保存後validation、kill/dispose/finally、最終EXE/report2件のみ。既存root/reparse/混在/超過停止。

## 実行境界と判定

実行前静的レビュー補足: Prediction104はprimary fixture比較、拒否後再比較12を別fieldで記録しtotal116とする（入力/呼出は増やさない）。uniformのq goldenも直接assertする。FIXED_STATSは凍結stats_jsonのDebug配列comma後spaceまで一致させる。

nonExecute初回はpool guardが禁止操作を説明するコメントのvector(q)を誤検出して停止。コード呼出integer_cts::vector(qだけを対象にする静的guardへ限定して再確認する。数値body/候補CLIは未実行。

frame peakの実績はencode成功直後、固定Proof/stats/容量guardより前に加算し、固定値拒否時も確保済みcurrent frameを漏らさない。内部codec allocationや全process peakには外挿しない。

workerはPS parser/Rustfmt stdout/nonExecuteのみ。compile・candidate CLI・Executeは親レビュー後親が1回実行する。正式benchmark/CPU/速度/holdout/4native/製品統合/全process peakは未検証。ABBA各2回平均両方向が短ければ次研究候補、片方向でも短くなければ保留。診断1周を統計的優位や正式gate合格と呼ばず、goal completeにしない。
