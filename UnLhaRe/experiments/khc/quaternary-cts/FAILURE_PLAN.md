# CTS機会診断の実装前失敗計画

正本: QUATERNARY_CTS_CONTRACT_20261002.md SHA256 20417FCEEE4A908725729B9E6CA09A90D7D66E78197464279CDA10B70C51A051。旧4expert source/proofと固定gateを保持する。これはdiagnostic f64仕様であり、旧binary Q32 wireの証明ではない。

コードを書く前に、以下を失敗可能性として列挙した。すべて有界メモリ内の診断または固定入力E2Eで検査し、raw trace/tableを保存しない。

| 失敗 | 検証と拒否条件 |
| --- | --- |
| 非対称KT、合法prefix1..4の分母・正規化が誤る | raw u32と独立u64 half-count oracleの全9level vectorを比較 |
| 0padding、最新child順序、16bit wrap、最大heap indexが誤る | 初期、全3の履歴、wrap系列、depth0..2全history/prefix/childを別除算pathと再帰式で比較 |
| 観測child/future/合法prefixがclassを変える | full区間による6classを独立区間topology oracleで各branch照合 |
| class分離・強制prefix1のchild0更新が抜ける | 分離系列とforced系列のcounts/history/observationsを比較 |
| leaf、深さ別混合、snapshot順序が誤る | 全branchのKT/mixed/旧weightと全更新weight/countを別posterior式に照合 |
| 初回alpha=.5、stationary/repeated/alternatingのswitchが誤る | 各系列で独立mass/(mass+childmass)と別switch式を比較 |
| NaN/zero/範囲外weightや丸め端を誤受理 | 固定tol外は拒否、tol内だけclamp、leaf=.5を検査 |
| invalid class/prefix/child、stale snapshot、count/class capが部分更新する | mutation前拒否、全state fingerprint前後一致を確認 |
| poolの符号・uniform・同snapshot・CTS weight0の学習/clampが誤る | 別normalized feature oracle、5特徴50中央差分、正学習/負clampを比較 |
| 既存4expert/hash/rescale/topology/grammarを変える | 前logpoolの8 component loss/cold/rescale/prefix/depth/grammar/oldflat照合 |
| 終端値数・全state照合が欠落する | base3187200+CTS2621442=5808642をshapeから算出し全値比較 |
| fixed input/rank/tree/escape/proof pinの変化 | 66049 tree、889227 rank、1778454 oldflat、3825340 branchとSHA/readlock前後照合 |
| import/parserが未pin sourceを許す | 実importのみ4source、unknown import/includeを拒否、CTS sourceもpin |
| compiler/runtime/options/容量/child制限が異なる | rustc1.98.1/pwsh7.6.5、one opt2 overflowyes、fresh root、8MiB/EXE1MiB/report512KiB/120秒/各stream65536を固定 |
| 結果後の再試行・tol/grid/rate変更・誤った成功宣言 | 実行一回、固定tol/FD/gate、full benchmark常時禁止、7-Zip総合goal未達を明示 |

数値tol=2e-10*(1+absA+absB)、FD step=1e-5/abs=2e-6、集計bits abs=1e-4。未知失敗後の同条件retry、tol緩和、rate/grid変更は禁止。親の最終source/hash確認まではcompile/runを行わない。parser/preflightだけ可。生成物はfresh build/khc-quaternary-cts-opportunity-20261002のEXEと小JSONだけ。Cargo/PDB/cache/frame/restoreは作らない。
