# split codecの正常比較条件

split codecの全E2E、生成診断、独立監査成功・凍結後、専用rootの未使用performanceへ1sessionのみ試行。controlはinline Q32+LUT EXE SHA `02C7D3D132DFD664CEA7BE643CDB0A5200583D5583AE101C715CC59FEF703083`。候補と同model/precision/grammar/SAIS/全frame、変数はsigned/wide guessの分離のみ。

親は凍結inline compare SHA `9405D089AD13D4D4E35178AA80B702C7B283844F6841B1E58782E8B87B92D87F` を再利用し、source/EXE/proof pinsとラベルを更新、新numeric/build/full proofをDFSへ追加する。旧全proof/readlocks、LUT清掃receiptの限定例外は保持。計測7helper AST、observer SHA E66D39AE...、preflight5回/全child前後15%以下、warm1+9/circular3codec/120秒所有child/fullCLIwall/table構築込み/memory-threadpollを変更しない。

native7za26.03 SHA EDBEE353...、mx9/LZMA2:d=64m/mmt1/solid/時刻metadataなし、group2811006B SHA18B8...、candidate/control frame483469B SHA7584...、archive<=483599B/strict encode<574.5624msを保持。最終decode/nativeSLTまで完了し全9回と全pinsが成立するsessionのみを局所採否の根拠にする。

busy/途中失敗時は自動再試行せず部分samplesを採用しない。CPU設定/他process停止/閾値緩和なし。新しいユーザー静穏通知等の外部変化は別sessionの再確認根拠になり得るが、実際のguardを通過したとみなさない。局所の比較成功と元速度gate・4native/holdout/製品統合・総合7-Zip超過を区別する。
