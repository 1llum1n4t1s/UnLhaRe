# 等カウントKT統合の数値証拠schema是正

初回buildは `build/khc-bwt-causal-bayes-q32-balanced-kt-20261001/build-report.json` SHA279820D21A1DAF7EE7E87DA9F4B23A1F26EB53E61D6ECDA9DC8B1579F22ADBBEでfailed、compile_calls0。数値proofの137invocationsに存在しないtimeout propertyをbuild/verify側が参照した。

## 是正前の失敗条件

- 数値proofを変更する、timeoutを成功値で補う、存在しない項目を無条件に無視して未知schemaを受理する、report/rootを上書きする場合は失敗。
- 数値invocationの実schemaはprogram/argv/exit/expected_exit/stdout/stderr。各required propertyを検査し、exitとexpected_exitを一致させる。数値verifierの120秒timeoutはthrowして記録追加前に失敗し、成功statusに到達しない。この源A798と正式proof63ACの固定SHA・成功status・全raw/idsを引き続き検証する。
- codec/full E2Eのtimeout propertyは別schemaなので削除しない。既存compile/codecの120秒制限・全79チェック・CRC/limits/no-clobber・87/178予定・数値/モデル/出力条件は変えない。
- required field欠落とexit不一致を人工recordで拒否し、正式137recordsを同じvalidatorで受理する実関数確認をしてから再ビルドする。これは単体テスト追加でなく、実証拠の境界確認である。

codec統合条件2D96と数値条件11ECは保持する。訂正実行の保存先のみ未使用 `build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix` へ分離し、元failed証拠を残す。親の契約/文書、専任workerのbuild/verify編集という所有を維持し、freeze後親が実行する。通常codec/CTS・数値source/正式証拠・旧正常候補は不変。
