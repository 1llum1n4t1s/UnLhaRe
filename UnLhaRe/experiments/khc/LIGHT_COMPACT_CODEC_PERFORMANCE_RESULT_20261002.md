# Compact light full候補の正式比較結果

最初のCPU preflightで終了。速度・改善率・中央値・7-Zip超えは未評価。この候補の試行はterminalとして保存し、自動再試行しない。

- comparer `light-compact-codec/compare.ps1`: SHA256 `485321A05E8FF30904F026E40573630563A3148B22ED64244F9FCC128F0C46E9`。旧node comparerから9件の全文明示対応、79一意support pin、8計測helper AST不変を事前確認した。
- 契約 `LIGHT_COMPACT_CODEC_PERFORMANCE_CONTRACT_20261002.md`: SHA256 `8FC3D6D6D4CA61EAEDADFCB385F19110433769BA530D83742618688603100B41`。
- attempt `../../build/khc-light-compact-codec-20261002/performance-attempt.json`: 963B、SHA256 `EC957ABA36E79EE9279BB63756C94FAA77DCA631C16B42D589AA8A2CA59AFC77`。
- UTC2026-10-01T20:31:52.0159596Z〜20:31:54.1778303Z。観測UTC20:31:54.1511367Zの総CPU32%が上限15%を超過。理由 `Host CPU busy; no ordinary performance adoption allowed.`、wrapper exit1。

codec/control/native CLI0件、warmup0・測定0件。performanceディレクトリ/reportは作られていない。history proof closureはpreflightより後なので未実行。事前79 pin/8 ASTと、full correctnessで照合した841 identitiesを、正式比較での全history closure再検証済みとは扱わない。

固定483599B以下・encode中央値厳密574.5624ms未満・総CPU15%以下・warmup1＋測定9・循環順・single-thread・CLI時間境界・子process120秒は不変。凍結observer/初期化位置を変更せず、priority/affinity/power/他processへ介入していない。後のCPU低下や別sessionのwarmupを合格へ読み替えない。

full正確性/サイズ結果は別report SHA9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BDの51/86/841。snapshot削減の実経路は確認済みだが、速度効果は未証明。

親合計23959118B（full23958155B＋attempt963B、約22.85MiB）。performanceの大きな出力・Cargo target/cache/PDB/raw traceは追加していない。旧terminal証拠は保持し、同候補を再実行しない。確認待ちの初期化分離は導入していない。

次の研究はモデル/数値計算の実コスト削減を独立候補として進める。正式計測を再開する方針を変える場合はユーザーの確認が必要。holdout/カテゴリ・同境界decode・四native決定性・製品/API組込みと安全性も未完了で、goalはactive。
