# entropy LUT 通常wireの結果

2026-10-04 Windows x64、compile1/native4の全child exit0、diagnostic-passed。製品コードは変更せず、速度改善としては未採用。

全32769 frequencyの表値を生成前後65538件、0/+Inf・32768/-0、範囲外2値を旧式とbits直接比較して差0。Kahan768更新のvalue/correction1536件も一致。実try_reserve容量overflow拒否1件に成功（OS OOM注入ではない）。表actual capacity32769/262152 bytes、digest4b6554e93db4bec2。表mut accessorなし、成功constructor容量TLS1writeのみ。既存Math/CTS/Trees構築成功後に表を生成し、constructor失敗優先を維持。

旧新の全frame478856 bytes直接一致、両方向全plain2811006 bytes入力一致。各型Proof14 Eq/型間全Debug14/全4statsが凍結通常版と一致、CRC/header検査成功。各self正常14/破損34/短header4の全文JSON一致。

| 単回内部時間（constructor含む） | control ms | candidate ms |
| --- | ---: | ---: |
| 圧縮 | 2176.4145 | 2163.6251 |
| 展開 | 2007.6884 | 1956.4460 |

約0.6%/2.6%短いがcontrol先行/warmup0/各1回であり、安定した改善ではない。正式fullCLIの574.5624/47.3884msとは比較境界が違い、特に展開の大差は依然残る。この小改善だけで総合目標へ十分とは判定しない。

pairの実OS peak working set55451648/private commit52006912 bytes、全4nativeの両peak160MiB以内。推定model21823416/encoder45985646/inverse47644808 bytes（actual表容量262152を加算）、32/64MiB source bound内。process peakとphase推定は区別する。

新出力EXE500736＋report152274＝653010 bytes、8MiB以内。大きな入力/frame/plain/traceコピー0、終了時空き54034989056 bytes。全source22/edge22/149479 bytes、164 unique pins。親readonlyは186 before/after/live組・raw4・全finite/Proof/stats/memory/容量式/出力形状を再照合exit0、追加compile/native0。git diff --check成功。

- report SHA256: `7E3BEAE5F533A90E2F6C5DCB038E69437339EE5EDB9A6158E29CA5D4B1B9F148`
- EXE SHA256: `3132912C7DA9000678F61D0087C6AE25A56175C21071E55C63B9A82680CC4E96`
- runner SHA256: `52974C9832A8B2D072B5778919AFFBC6F78E5A90B3A37E4CF85E1FE814F71A14`
- readonly SHA256: `0E3434051C1A29C08D8C4027A06940D7AFDEBED185ED320BD5E1D306B47CC151`
- 再照合: `pwsh -NoProfile -File UnLhaRe/experiments/khc/hard-cut-entropy-lut/verify-readonly.ps1 -ReportSha256 7E3BEAE5F533A90E2F6C5DCB038E69437339EE5EDB9A6158E29CA5D4B1B9F148`

静的CDF headerだけの改善は全保存費用無料でも既定screenが213B超過し不支持。Beamの前倒しdominanceはslot順の反証と既往速度回帰があり新候補なし。次はtransformの依存loadを複数のLF walkerへ分ける構造の正当性を確認する。追加metadata/encoder費用は実計上し、payload/モデルの速度不足とは別に扱う。全CLI/quiet/holdout/完成書庫/API/4native、7-Zip総合GOALは未達・active。
