# flat四expertの楽観的envelope診断（コード前）

前exact-contextは566837Bで不採用。異なる文脈の混入だけでは足りない。読み取りanalystは木nodeごとの条件付け/4608重み、class別5child履歴CTS、第5featureを含むlog-linear積混合の三差を確認したが、寄与のablationがなく新候補0。単独効果を推定しない。

次の問いは固定四expertの凸混合を続ける価値。実際の観測tokenを知った後で最大count/合法prefix totalのexpertを毎回選ぶ、実装不可能なoracleを診断する。各expertのcount履歴は全expert同時更新であり、混合重みから独立。新ルートconvex-envelope/のprobe/runnerだけを親が所有し、exact-context/等旧root/source/resultは読み取り専用。製品/API/wire/版/依存/Git/削除/外部write/追加委任なし。

## 先行失敗条件

浮動小数で最大expertを誤選択、count/total範囲外、合法prefixでなく257全totalを使う、観測後countを使う、更新順変更、tokenを事前に知れる符号化と誤認、integer ceiling overflow、全混合方式の不可能性と誤称、実frame/速度へ外挿、入力/source drift、出力/RAM/time上限超過。

最大比率はu64 cross-productの厳密比較、count/total各1..32767を検査。理想確率の凸混合は最大expert比率以下。Q32768のreserved-one cumulativeでは実数演算上frequency<=1+ceil((32768-limit)*最大比率)。診断はさらに2frequencyを無料にしたupper=min(32768,3+ceil(...))を採る。このextra2は楽観的な余裕で、f64 wireの全実装を証明するものではない。整数frequency上界からlog2 lossをKahan合計する。比較はceil(loss/8)+3079対483599。passは実用性の証拠ではなく、failでもこの固定count/feature/更新の凸混合族だけの必要条件診断。積混合、新CTS、別counts/feature一般は除外しない。

コード前fixtureはratio選択(1/257,2/5,3/5,1/1)、同率、cross-product安全、limit1/257、Qupperの端点、count0/total0/count>total/total32768/limit0/258の拒否。小fixtureと全入力で別の走査順の最大比率選択もcross-product照合する。新unitなし、単体診断入口に有限チェックを含める。

固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一read/BWT/Front walk。rank/length各889227、run889227、escape742、history1778454、grammar58735a2b7383d755。predict前のcountsをoracleへ読み、元observeは一回。終端whole model/map照合。元exact必要loss4510058.854214707も同時に一致確認し、この再現は設定再試行や速度選別ではなく新envelope観測の基礎照合。prefix追加queryはreadopsのみでcountsを変えない。

rustc1.98.1/edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、cfg frame_audit/primitive_audit。source300KiB、EXE1MiB、report256KiB、streams64KiB/16KiB、全出力8MiB、空き5GiB、compile60s/native120s、単一実行。RAM160MiB、input/BWTとmodel phaseを分離、終端WinAPI実peakを記録。新Cargo/PDB/rawtrace/input/frame/plainコピーなし。source/input/tools/resultを前後live pin、process0、read-only最終照合。今回の結果だけで7-Zip総合目標を完了しない。
