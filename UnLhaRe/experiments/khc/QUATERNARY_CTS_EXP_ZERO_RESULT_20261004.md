# exp(0)短絡の反証結果（2026-10-04）

数値・E2E契約は一致したが、圧縮側が遅くなったため固定の両方向短縮gateで非採用。
一周だけの診断であり、展開側の差を正式な改善率や7-Zip超えとして扱わない。

| ABBA一周・各方式2回平均 | 旧版 | 候補 | 候補の時間差 |
| --- | ---: | ---: | ---: |
| encode | 7091.2599 ms | 7228.86685 ms | +1.9405% |
| decode | 7519.08425 ms | 6625.11385 ms | -11.8894% |

warmupなし、同一binary old/new/new/old、各encode/decode4回。コード配置・CPUスケジューリング等の影響を含む。
前日の計測と環境負荷・実行時間が異なるため、別実験の値を混ぜて改善率を算出しない。同条件の好結果狙い再試行は行わない。

## 変更と検証

- 既存domain検査後の `d==0` だけ `Ok(Q)` を返す新private Math。pool数値bodyは不変、候補型へのimportのみ。旧ソースは変更していない。
- 独立読み取り専用analystで配線、Proof14field、全byte比較、timeout/容量/失敗報告の静的検証を実施。要求・実効はrole既定 gpt-6.1-sol / medium。実装workerも同role既定。正式CPU/holdout/native/product gateは未検証。
- compile1回、compare-math1回、ABBA CLI1回、全exit0。compile 3196.9657ms、Math135.6157ms、ABBA57137.2197ms。compile stderr998B（warning）、CLI stderr0。
- 全LUT各4097/count32769要素、exp固定12/grid近傍405603、ln固定49/grid近傍405603（3方式ずつ）、count境界5、決定的正値4096の直接比較pass。無制限の生トレース保存なし。
- 全plain2811006B×4回一致、全frame478750B×3回=1436250B一致。encode/decode・firstAとのProof全14field（CDF bits）とstats直接比較一致。サイズ483599B上限維持。
- 189 identitiesのSHA256/bytes/mtime_utcをbefore/after/live照合し不一致0、source graph16件。実行前nonExecuteで基点、空process戻り値、空文字Replaceを修正したが、この段階ではcompile/候補CLIとも0回。
- 新source8file合計83823B。生成物はEXE418816Bとreport77659B、合計496475B（約485KiB）のみ。report書込前disk_after.usedはEXEだけで、最終容量とは区別する。空き約70.46GiB、所有候補process0。削除なし、Cargo/PDB/frame/restore/input copyなし。

## 固定証拠と次の判断

- report: `build/khc-quaternary-cts-exp-zero-20261004/report.json` SHA256 `42BD5E85FAEB54853BCA75D4ACD90140FB85927F2DADB93F4AAE0EF68CEE4F19`、77659B。
- EXE: 同root `exp-zero-o2.exe` SHA256 `E4C79D4BC63885527B32EA17B05E349DD04C3383232BCF512D47A94E8742D0AD`、418816B。
- 先行失敗計画と実行入口は `quaternary-cts-exp-zero/FAILURE_PLAN.md` / `verify.ps1`。既存outputを再使用する実行は拒否し、証拠を読取確認する。

次は旧Q32の予測をCTSとpoolへ分離する限定診断。今回のexp短絡は数値的に安全でも、採用条件を緩めて採用しない。固定総合goalは未達。
