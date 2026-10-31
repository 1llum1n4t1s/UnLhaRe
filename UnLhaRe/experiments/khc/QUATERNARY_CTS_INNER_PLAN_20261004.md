# CTS内部診断の事前計画（2026-10-04）

目的は既存のCTS/pool診断で未分離だったCTS内部の時間を調べること。速度候補の採用・製品変更・固定ゲートの変更は行わない。

## 失敗条件を先に固定する

- 数値body、guard順、snapshotのDerefMut/完全一致契約、更新前の全準備またはcommit順が変わる。
- 入力・コンパイラ・既存ソースのSHA256/bytes/mtime_utcが前後で変わる。
- 固定frame全478750 bytes、plain全2811006 bytes、Proof全14 fields/CDF bits、stats全22 fieldsの直接比較が不一致。
- sample位相が既存のcomponent×prefixごとの1-based ordinal % 256 == 128と異なる。総数3825340、sample14942/directionを満たさない。
- predict/observeのsample対応が不一致、未完了scope、timer合計の矛盾、overflow・拒否で診断状態が部分更新される。
- source300 KiB、EXE1 MiB、report256 KiB、実行root8 MiB、空き5 GiB＋8 MiBを超える。native出力上限64 KiB/16 KiBを超える。
- 既存rootを上書き、共有cacheやx86版を変更、raw frame/plain/corpusコピー、PDB/assemblyを保存する。

## 診断仕様

新規root `quaternary-cts-inner-split/`、生成root `build/khc-quaternary-cts-inner-split-20261004/` のみ。凍結済みpredict-splitを元に機械複製し、明示allowlistの診断挿入だけを許す。

predict: guard/gather、Kernel、snapshot構築/seal。observe: guard/gather/freshness、certification/必要fallback、update/prepared/commit。通常とfallbackの件数を区別する。sample対象外の時計取得をしない。親時間と子時間の二重加算を避ける。論理field量ではなくsize_ofの実サイズも報告する。

compile1回、時計を使わない直接契約CLI1回、baseline encode1回→診断encode1回→診断decode1回を1CLIで実行する。既存model診断は改変拒否を確認するが修復後受理を検証していない。別の直接CTS契約診断で、別certifiedを持つsnapshotのvisibleをDerefMut経由で現在predictとexact一致させた場合の受理、正常受理、stale・derived・未使用tail改変の拒否前後全Cts state保存を旧/新双方に確認する。未観測の時計試行はnull、診断のclock/配置影響を明記し外挿しない。

複雑なsample対応は実装前に反証し、侵入量が大きい場合はpredictだけの最小splitに縮めてobserveを未測定と明記する。E2Eと再現可能なJSONを残し、ユニットテストは追加しない。実装担当1人、独立した読み取り検証後に実行する。
