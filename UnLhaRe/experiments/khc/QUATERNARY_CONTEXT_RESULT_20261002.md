# 4分岐・構造文脈の機会診断結果

判定: 混合entropy+escapeは4278427.963862260bitsで、固定payload機会予算3866504bitsを411923.963862260bits（51490.495483byte相当）超過。不採用・整数wire/full/正式benchmarkへ進めない。実frameサイズや速度を測った結果ではない。

old flat比ではrank3384815.145283996→3159178.789736769bits、length1212902.289895460→1113313.174125491bitsとなり、合計325225.471317196bits（40653.183915byte相当）減少。豊かな文脈とprefix共有の方向には改善証拠があるが、7-Zip超えには不足する。

| predictor（bits順序） | rank bits | length bits |
| --- | ---: | ---: |
| mixed | 3159178.790 | 1113313.174 |
| global | 3567595.606 | 1201641.008 |
| symbol | 3675548.212 | 1192246.948 |
| recent | 3487884.376 | 1206939.480 |
| joint | 3364303.958 | 1202294.268 |

mixedはどの単独expertの全体損失よりも良く、expertを固定選択する置換では解決しない。適応的混合が役立つが、算術mixtureだけでは予測の結合を十分に生かせていない可能性を次の反証仮説にする。これは幾何poolの優位性を既に証明したという意味ではない。

全889227rankを別positions/cursor/count oracleへ照合、grammar digest両方58735a2b7383d755一致。全66049 token/limit topology、各142内部node、最大depth7。rank2725772/length1099568枝、計3825340枝のcounts/確率/posterior/share/rescaleを別配列・別式へ逐次比較。終端3182592state値一致、old interval1778454件もprefix式照合。global/symbol/recent/joint rescale378/56/116/7、cold枝741/36502/123934/105247。parentもsource/runnerでcausal更新、既知rankContext、独立rankoracle、tree/CDF照合を読取り確認した。

one opt2/overflowyes CLIでstatus passed、3childのstderr空。source/import/compiler/runtime/proof/input識別16個とEXEを前後・親再照合、差異なし。親がgateとbytesを実reportから再確認。4compiler/native/整数化・wire・正式速度・holdout・製品/APIは未検証。

report build/khc-quaternary-context-opportunity-20261002/report.json14861byte SHA D5F126BCD9F86D0A355AE7A8F5CB1550E23DA5F58A8F045E5C5281E055357D99。
EXE226816byte SHA6F7AE4DB196FAE2EE7F1FF876653F6EC6B2FD673D33ED4F38A8A5C8D4FB4CED2。
source653BD8743F71ED0CEF5D9C6F146C794A0A098ACAC20112774C43CCE3FCB0434D。
runnerECA619D08C36627125F28FBF874E0D1E466A14980D6DE3006CB504F0B9EF88A0。
failure plan5C3271D7C3EF0AD197648D0C3D7B7641C5D71DBFC1D674B0F5E62D20DD2EBE05。
2保持file241677byte（約236KiB）、8MiB cap内。frame/restore/rawtrace/Cargo/PDB/cacheは生成しない。source/契約/proofは凍結、Gitstage/commit/push/version/公開/x86は変更しない。全7-Zip超えgoalは未達・active。

