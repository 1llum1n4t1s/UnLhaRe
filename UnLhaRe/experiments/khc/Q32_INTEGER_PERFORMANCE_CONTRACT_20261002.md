# 整数refinement: 通常full CLIの正式比較（実行前契約）

対象は新通常native238080B SHA `AD2D1D930F27FA73B70F1E096BBEDC35301244B0A2FA3130F689680430184A26`。完全codec proof `B7BE539DB0DA5786EAAA1BC7F4E43DC983A4495F21E6B2E80BADD999407D459D` の32checks/53CLI/141identities、完全frame483496B SHA `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12` に結び付ける。数値proofはwide/narrowの各9293629件×opt2/3。新しい整数構成の初回正式比較であり、旧CPU静穏失敗の自動再試行ではない。

固定入力はKHSGRP0、2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。ゲートは完全frame≤483599B、単thread full CLI encode median strict<574.5624msのまま。controlは凍結balanced KT217088B SHA `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0`、frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。旧scheduler同値は前段のcodec E2Eで確認済みだが、ここで旧scheduler単体とのisolated速度比を測ったとは主張しない。

基準native7za26.03 x64、1335296B SHA `EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0`。manifest11ファイルの本文/順序/長さを検証し、`-t7z -mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mta=off -mtc=off`。両研究codecはgroup1出力、nativeは11出力なので、decode時間は診断のみで採用判定へ混ぜない。

旧 `causal-expert-scheduling/compare.ps1` SHA `785727BDEA01C90788707E352B215048D9934DA1848FFC5982BFBD4402EC69C2` から明示置換で作る。8関数のAST本文、quiet observer SHA `E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF`、process開始からexit/stdout/stderr drainまでのwall、child CPU、1ms要求OS thread/peak sampling、120秒timeout、warmup1+9、3方式循環、中央値/paired比計算を保持する。codegen/static命令数は速度と読み替えない。seed262144BとKT524296Bの初期化/lookup、journal/replay/BWT/grammar/全I/Oを含む。

旧proofのDFS/全support pinsを保持し、新codec/narrow/wide proofを追加する。ただし2つの新数値proofにあるcapacity guardの旧SHA `379BFC1CCE693FCADD75AD6D8C375FEA2F10151EBA4B63D8462ADA91C2051BBF` は歴史的実行記録と明記した修正前sourceである。この2文書内のrole=budget-guard、exact path、before/after旧SHA、1997Bの1件ずつだけは、修正済み現在SHA `F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7` /2054Bに対応させ、例外をreportへ記録する。現在のguardは新codec proofでも実行・保持済み。math/helper/compiler/EXE/結果/計測閾値は変更していない。他の不一致・欠落は例外にせず失敗する。全u64数値正当性の証拠と、この非数学的guard修正を混同しない。

生成先は `build/khc-causal-integer-refinement-20261002-comparison-repair/performance`。既存拒否/CreateNew。見積り<64MiB、事前/事後256MiBチェック、raw/ETL/全assembly/新Cargo targetなし。quiet preflight5回、全CLI前後total CPU≤15%。busyなら失敗で停止し、自動再試行/priority/affinity/power変更/他process停止をしない。preflightでroot未作成のときも親のattempt記録で観測を残す。

失敗条件: pin/長さ/ancestor/reparse差、proof不備、metadata/本文/復元差、完全frame/hash違い、非決定性、CLI失敗/timeout、静穏違反、warmup/9round不足、source/input/binary変化、容量予算超過。判定は失敗/不成立のまま残し、ゲートやアルゴリズムを調整してその測定を通過させない。

Windows x64/Ryzen5 7640HS 6C12T/rustc1.98.1の実現在値、runtime path/version、script path/mtime/SHA、解決後CWD、power scheme、observer/manifest/input/binariesを記録する。4native、holdout/category、同境界decode、製品統合、安全性/APIを含む総合goalは、この単一開発測定で完了にしない。
