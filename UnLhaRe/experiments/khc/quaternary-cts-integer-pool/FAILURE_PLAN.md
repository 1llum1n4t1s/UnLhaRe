# 5特徴整数pool・全入力機会診断の実装前失敗計画

コード前に保存。正本 QUATERNARY_CTS_INTEGER_POOL_CONTRACT_20261002.md SHA256 EE130558C966D6C96DE8887050A01D39FA3FDC59802AC70A867BC0DD53BE28FA。

| 失敗可能性 | 固定検証・拒否 |
| --- | --- |
| lnのzero/domain/符号/shift、signed divisionの負丸め、指数・grid境界、18項・内部floor・LUT補間を誤る | count32768、CTS境界97/grid81941、L4097をbinary long division別oracleへexact比較、real abs2e-8、LN2 fixture |
| expの符号/128Q/domain、24項・内部floor・補間・cutoffを誤る | E4097/exp32769を別oracleへexact比較、real abs2e-8、E2048/cutoff±1/端点、LN2誤差とcutoff余裕を固定 |
| unsigned/signed積・合計・conversionがoverflowする | checked u128/i128、非法domain/overflowをコード入口で拒否 |
| 主LUTやsnapshotをoracleへコピーする | oracle別起動計算/配列、smallは128step divrem、全入力は別式・native u128と区別して記録 |
| scoreをfeatureごとにtrunc、normalized count featuresへ変更する | raw count4+lnCTS1のcanonical feature、全積合計後だけtrunc、独立pool exact比較 |
| softmax最大、q zero、非合法tail、128Q幅、Hamilton tieを誤る | prefix1..4/rare/CTS最低最大/zero/high/各expert変更、余り別ranking、最大expQでzero total防止 |
| uniform factor/合法最低、勾配符号・負delta丸め・同snapshot・clipを誤る | factorと5expected/gradient/delta/next全値、CTS weight0正学習/負clamp、50中央差分は理想real gradientのみ |
| forced1でpool/CTS更新が混同される | q=P=Q/gradient0/weight不変、CTS switch/count/historyは更新 |
| CDFの総和・頻度最低2・tie/cumulativeを誤る | 全branchのHamilton F32768/CDF exact比較、観測前確定、CDFentropyをprimary gateに固定 |
| 局所real比較を別f64連続軌跡へ拡張する | 同integer snapshotのみ、q相対+絶対/ P2e-6/grad2e-3/next1e-5、旧tol2e-10維持 |
| invalid counts/CTS/weights/prefix/child/cap/staleでmutationする | predictはchildなし、拒否前後の全状態直接比較、全prepared update後commit |
| 旧grammar/tree/rank/run履歴/count/hash/rescale/expertを変える | tree66049/rank889227/oldflat1778454/grammar58735a2b7383d755/3825340枝、前f64 proofの8損失/cold/rescale/prefix/depthを照合 |
| CTS class/history/path/half-count/weightが自己一致だけになる | frozen主CTS import＋独立oracle、全9level/全枝/終端5808642値exact比較、class観測固定 |
| P entropyだけでgateを成功にする | primaryはCDFentropy+5936 <3866504、Pentropy別記録、fullbenchmark常時禁止 |
| import/pin/環境の差替え、旧証拠の変更 | 6source/5edge、contract/oldproof/result/source/input/guard/compiler/runtime readlock前後hash |
| runner validator失敗でparsed audit/実行前EXE identityを失う | reportへEXE_beforeとparsed auditを検証前に保存、scalar bound式をpreflightで評価、failure JSON保存 |
| 容量/出力/timeout/同条件retry/結果後のtol/grid/rate変更 | fresh8MiB/予想512KiB/EXE1MiB/report512KiB、120秒/各stream65536byte、one opt2/overflowyes/noDebug、nooverwrite/retry |
| pool成功をwire/actual frame/正式性能/全goal成功と誤認する | range/frame/Cargo/PDB/cache/restore/rawtrace/table出力なし、正式CPU/holdout/native/product/API未検証 |

parent最終レビューまでcompile/候補run禁止。parse/rustfmt stdout（書換なし）/-Executeなしpreflightのみ可。旧4files/failedroot/closure/proofは凍結。Git stage/commit/push/version/公開/外部書込/x86/共有cache禁止。数値上限を実行結果後に変えない。結果はEXEと小JSONだけ、全goal active・未達。
