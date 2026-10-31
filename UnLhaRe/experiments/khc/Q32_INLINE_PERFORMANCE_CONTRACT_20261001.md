# Q32 inline候補の正常比較

新inline候補の全E2Eと独立監査成功後、専用build rootの未使用 `performance/` へ1sessionのみ試行する。対照は凍結LUTあり・inlineなしEXE SHA `A3981BC785F0DC3F5882EED62F49DC12C4911FD045773AEC6646417E3BCD2010`。両者は同Q32/Bayes表/SA-IS/grammar/全frame、変数は商helper/wrapperのinline指定だけ。対照の性能採用が済んだと仮定しない。

親は旧LUT compareを再利用し、候補/controlのSHAとラベルを更新、新source/contract/build/full proofを追加、旧全proofとLUT清掃receiptの厳密な例外処理を保持する。計測helperのAST、quiet-host SHA E66D39AE...、preflight5回/child前後15%以下、warm1+9・circular順序、fullCLIwall、所有child120秒、memory/thread pollを変更しない。

native7za SHA EDBEE353...、mx9/LZMA2:d=64m/mmt1/solid/metadata時刻なし、固定group2811006B SHA18B8...、候補/control frame483469B SHA7584...、archive<=483599B/strict encode<574.5624msのgateを維持。inlineでtable構築を除外せず、全CLI時間に含める。

busy/途中失敗は採用不可。同候補・同区間のblind retry、他process停止、CPU設定、guard緩和をしない。完了9rounds/直接初回最終復号/native metadata/全pins一致を確認する。局所inline効果と総合7-Zip超過を区別し、holdout/4native/製品統合の未検証を明記する。
