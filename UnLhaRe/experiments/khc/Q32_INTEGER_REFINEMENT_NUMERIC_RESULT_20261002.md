# 整数seed/refinementの数値結果と機械語

数値段階は通過、速度改善は未証明。`build/khc-integer-refinement-20261002/report.json` SHA `A956525D2234A000353B8E33E54BEB6B48C366A8CD64FF6F23E7B439B96EEFE2`、status `numeric_verified_not_codec_or_timing`。opt3/opt2でそれぞれ9,293,629件を逐次u128直接除算oracleへ比較し、全summaryと非暗号学的rolling fingerprint `51b49b146351fbd2` が一致した。BigIntegerによる別計算の14queryも成功した。

| 範囲・経路 | 件数 |
| --- | --- |
| 小分母1..65536の商境界 | 1,114,112 |
| 全32768seed bucketの代表3点×8shiftの商境界 | 7,077,888 |
| D=Q-k、k1..80の特別境界 | 38,400 |
| 固定seed random/二因子積 | 1,062,500 |
| d0/overflowを含む特殊直積 | 729 |
| refinement | 8,274,640（うち1up補正4,187,973） |
| power-of-two shift | 893,374 |
| 正常domain外の直接除算fallback | 125,326 |
| 期待通りの境界エラー | 289 |
| 正常domainのcertificate fallback | 0 |

4checks/23CLI/8held identities、source/compiler/EXEは実行前後SHA一致。seed表262144B。失敗計画と数学domainは `Q32_INTEGER_REFINEMENT_CONTRACT_20261002.md`。生recordは保存せず、実行が各recordを直接比較した。数値root約2.94MBで、新規Cargo targetは作っていない。

既存split診断担当による追加の読み取り確認では、opt3 EXE SHA `87129846CA9F17129006AEA11A1FE9B3462B8AF6A0E461C0E1DF4E776A630779` を、固定llvm-objdump SHA `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA` で確認した。0x140002352–0x140002431の通常refinement/certificate成立経路は64命令、mulq6個・imulq5個、DIV/CALL0。0x140002417/424の不成立分岐のみ0x140002586の直接除算fallbackへ進み、成立は0x140002431から0x1400025bcへ迂回する。数値auditにも同形がある。

これは実EXE内の命令列の静的証拠。ソース49–66行との対応は命令構造からの推論で、PDB帰属・動的cycle・wall timeではない。以前の担当の補足であり新独立作者レビューではない。

次の根拠付き変更は、中間のreciprocalをu64に保ち、normalized divisor積がu64内に収まるdomainを局所化すること。現在のu128 stateが余分なwide乗算・carryを作るためで、単にDIVを除いたという理由で採用しない。narrow版は別契約・別source/rootで正確さと命令列を確認する。現時点でcodec全frame同値・固定サイズ/速度ゲート・四native・holdout・製品統合は未検証。
