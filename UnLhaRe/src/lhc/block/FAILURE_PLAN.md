# 製品block portの失敗先行契約

LHC_PRODUCT_BLOCK_PORT_PLAN_20261005.mdとUnLhaRe/AGENTS.md全文を確認した。製品block配下だけを所有し、親がcontainer/API/CLI/E2E/文書を所有する。frozen repair1 codecとwireを維持する。

| port固有の失敗 | 保持する検査と責任 |
| --- | --- |
| experiments/root namespaceへ残存参照 | 全moduleをblock内部へ独立portしsuper参照。srcからexperiments path参照0 |
| OS診断・teacher・旧baseline混入 | memory API/teacher/旧形式/古い再課金/大規模referenceを除外しSOURCE_MAPへ明記 |
| wire/整数CDF/履歴差異 | MAGIC/rev/header40/257book/LUT/grammar/range/CRC/stored利益条件を変更しない。親が同有限入力・固定3block・30故障とbyte/費用直接比較 |
| 1MiB上限・capacity欠落 | encode/decodeのallocation前上限、checked長、visited LF、正準escapeとCRCを維持。codec64MiB/scratch64KiB、新source160KiB/閉じたcodec350KiB |
| 見かけの完成 | workerはcompile/native禁止。syntaxだけで型/実動作/4環境/優位を達成主張しない |

新mod.rsはpub(crate) encode/decode Result<(Vec<u8>,Stats),String>とMAX_INPUT/HEADER/MAGICを提供。親の追加指示に従いencode_low_history_onlyを追加し、選択のみ低固定・high Hist/Fit省略・共通wire/decoderとする。SOURCE_MAPに出典と削除・参照変換の明示diffを保存する。既存製品dirty editsとfrozen実験sourceを編集しない。apply_patchだけを使用。compile/native/cache/download/Git/削除/外部/version/追加委任0。完了時は合計/契約/未検証を返し編集停止。
