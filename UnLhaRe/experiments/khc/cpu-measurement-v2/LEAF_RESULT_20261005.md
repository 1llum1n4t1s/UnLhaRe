# Leaf候補の費用選択：採用結果

2026-10-05 Windows x64。通常quantized compact leafに加え、既存wireのuniform/pureをloss＋保存bitsで比較する変更を製品paid_modelへ採用。元候補を必ず残し、厳密な改善だけを選び、splitは選択済みbest.lossと比較する。CDF保存形式、decoder、version、CRC、public APIは不変。新しい圧縮原理とは主張しない。

## 事前ゲートの判定

LEAF_PLAN_20261005のdevelopment2入力の採用基準を変更せず判定した。

| 入力 | Paid frame旧→新 B | 圧縮中央値旧→新 ms | 復号中央値旧→新 ms |
| --- | --- | --- | --- |
| alice29 | 43436→43267 | 309.274→309.707 | 143.226→140.198 |
| kennedy | 81808→80854 | 749.775→791.866 | 306.695→300.851 |

合計125244→124121 B、1123 B（約0.897%）縮小。各入力ともサイズ悪化なし、圧縮・復号中央値は各旧版110%以内、最大観測RAM64MiB以内で採用。kennedy圧縮中央値は約5.6%増えた。min/maxの重なりがあるため速度優位とは主張しない。Lowは127935→125655 B、2280 B（約1.782%）縮小。Low alice圧縮278.079→267.475 ms、kennedy675.889→674.794 ms。

syntheticではrepeat4KiB 297→293 B、all256×8 809→804 B、random64KiB/empty/1Bは同サイズ。全入力の辞書・モデル・header/CRC・range終端を含むfullframeで計測した。入力の一部費用を外部化していない。

## 安全性と回帰

- Paid/Low各294、合計588 native呼出し完走。各140組の自己復号、14回の双方向cross-decodeで元byte完全一致。新frameを旧decoderでも復元した。全source/input/helper pin前後一致。
- modeごと70符号列対の30対同一・40対変更。encoder戦略変更なので同一frameを採用要件にしないオプションを明示した。形式変更ではない。
- 固定3block新frameは156483/237176/119861 B。凍結基準157149/237852/120312 Bを保持し、合計1793 B縮小（約0.348%）と元byte復元を確認。
- 固定費用E2Eの「旧encoderとサイズ完全同一」assertは、形式がcanonical encoderを要求しないため「保持した旧基準以下」へ変更。数値や元のreportは書き換えていない。このE2E変更を7-Zip完成ゲートの変更へ流用しない。
- `cargo test --locked --offline --release --target x86_64-pc-windows-msvc --test khc_block_normal --test khc_block_adversarial --test khc_model_boundary -- --test-threads=1` 成功。固定all.groupを環境変数UNLHARE_KHC_FIXED_INPUTに指定。30故障/30回復、有限入力とoversize、最大分割モデルを含む。
- `cargo clippy --locked --offline --release --target x86_64-pc-windows-msvc --lib --example khc_leaf_probe --test khc_block_normal -- -D warnings` 成功。変更3Rustのrustfmt check、対象diff check成功。
- 今回全repo回帰・container E2E・非Windows nativeは未再実行。container/filesystem/decoderは変更せず、製品block公開APIで検証した。

E2E成果物：build/khc-product-e2e-20261005/block-normal-8604/result.json、block-adverse-43092/result.json、model-boundary-46616/result.json。

## 再現と保存

新khc_leaf_probe targetのみbuildし、旧khc_active_probe EXEは保持。CPUプロセス起動・binary I/O込み、同じrunnerでwarmup1＋9測定、旧新順交互。純codec CPU測定ではない。

`run.ps1 -NewHelperExe <khc_leaf_probe.exe> -NewHelperSha256 A92088A87879B4328EA61179BCAD7BAB741D1BE2CB9DACE1598C523FBE2F234D -BaselineHelperExe <khc_active_probe.exe> -BaselineHelperSha256 254286AE96D9AB7654553B6B6613E0314C0D324C3A27B6A201CAC2BF16991B7F -Attempt <未使用名> -HistoryMode paid -AllowDifferentFrames`。Lowはmode lowで別Attempt。

- Paid report：build/khc-cpu-measurement-v2-20261005-leaf-paid/report.json、24976 B、SHA256 B3A8B97DE80E94DA6848691942772E65117E23F1E0B5EF069D027B2EED49A5CD。
- Low report：build/khc-cpu-measurement-v2-20261005-leaf-low/report.json、24936 B、SHA256 90E41BD377B075D84CC70D14D51F6602CBED05CF9FB663C6FC1BCA816766F1D7。
- report計49912 B、生入力/圧縮物disk保存0。E2E累計6324884 Bで8MiB以内。
- 共有Cargo累計6111746518 B、元baselineから204953438 B追加、256MiB上限内（残り63482018 B）。空き約30GB、削除/新依存/Git/公開なし。

opop基本6観点の採用分を親が実装・検証した。Performanceは実fullframe改善、Hardening/TesterはCDF・cross-decode・上限を維持、Cleanerはleaf score共通化へ統合。Modernizer/Normalizerは独立変更不要。Asyncは既存progress pumpを維持、Startup/Intelは今回非該当。今回は新規委任なし。

## GOAL未達と次の実験

本結果は2つの既知development入力を使った局所候補の採否であり、代表全体・未見評価・7-Zip優位の証明ではない。GOALはactiveのまま。GOAL_GATE_20261005の完成基準は維持する。

次は更新版と既存7za26.03のLZMA2/XZ mx9・1workerを、同一progress runner/同一input/64MiB制約で測る。1MiB独立blockの診断では入力より大きい4MiB辞書を使用し、総サイズ・圧縮/復号時間・peak RAMを明記する。7-ZipとKHCは別形式なので自己復号で元byteを検証し、相互復号を装わない。Zstdと現行方式も広い評価で再比較する。独立blockの診断をsolid/archive全体や未見データの勝利へ拡大解釈しない。
