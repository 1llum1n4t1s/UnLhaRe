# categorical Q32 CTS primitive 実装前失敗計画

コード前に保存。正本 QUATERNARY_CTS_Q32_PRIMITIVE_CONTRACT_20261002.md SHA256 3A5FD8AB1A03A834A4F497B8734A2F44468F38B7A1ACD11D02674758D075C14D。

| 起こり得る失敗 | 固定診断と拒否条件 |
| --- | --- |
| Hamiltonの商・剰余・tie配分・sumQが誤る | 独立128step binary divisionと別ranking、tie child昇順、全5184 KT、zero/negative相当の非法massを検査 |
| prefix1のQ、非合法tail0を拒否/混入する | prefix1..4、非合法raw差替え、forced1更新を検査 |
| u64前提でQ²/Q³、mass合計、mass*Qがoverflowする | checked u128、Q²端点とu128 overflow、zero total、zero合法prob拒否を検査 |
| raw全totalと合法totalを取り違える | 全1296 raw0..5×4prefix、cap/超過/非合法raw capを検査 |
| 16bit history、最新child順、heap index、0paddingを誤る | 全65536履歴×9levelを除算pathへ照合、最大index87380、6class分離/wrap |
| mixedの深さ順・leaf・snapshotが誤る | 小depth0..2全history/prefix/childを本体kernel経由で独立再帰oracleへ照合 |
| posteriorに丸めmixed*Qを使う | 保存rawmassからu128 ratio、親BigInt prefix4/2 fixture、端weight5種と非対称/cap寄りの検査 |
| alpha/switch端点・初回・cap直前が誤る | before0/6/CAP-1、alpha floor、post/next範囲、leafQ/2とforced1のswitchを検査 |
| 観測childがpredictへ漏れる、class/futureで履歴を混ぜる | predict(class,prefix)のみ、別oracle配列、各系列の全9level比較 |
| 更新途中にcap/invalid/stale/overflowで部分mutationする | prepare全検査とallocation後commit、実observe入口で拒否、clone全state直接比較 |
| oracleが主snapshot/normalizer/updateをコピーする | 別half-count、別path、独立div/rem/ranking/再帰・更新式、終端2621442値exact比較 |
| 局所誤差を連続系列や理想raw posteriorへ拡張する | KT/再帰mixは2*(depth+1)/Q、post/switch4/Qは既Q32 KT/child/同weightの一更新だけに限定 |
| f64旧tolを拡大し同値を誤主張する | 旧tol2e-10維持、新integer exact証明と局所誤差報告を分離、軌跡/entropy/wire未検証 |
| import/契約/旧証拠/実行環境の変更 | 2source/1import、pin/readlock前後hash、rustc1.98.1/pwsh7.6.5固定 |
| 容量超過、子停止、過大出力、重複実行 | fresh8MiB、EXE1MiB/report512KiB/予想400KiB、120秒/各stream65536、one opt2 overflowyes、no overwrite/retry |
| primitive成功をpool/gate/実frame/総合成功に扱う | standalone numerical diagnosticのみ、ln/exp/gradient/CDF/range/fullbenchmark未実施を明示 |

parent最終source/runner/hash確認までcompile/runtime numerical diagnostic禁止。parse、rustfmt stdout、-Executeなしpreflightだけ許可。結果はEXEと小JSONのみ。rawtrace/table/frame/Cargo/PDB/cacheを保存せず、旧source/proof/rootを変更しない。Git stage/commit/push、version、外部書込、x86、共有cache禁止。失敗時の同条件retry・数値上限/tol変更禁止。全goal active・未達。
