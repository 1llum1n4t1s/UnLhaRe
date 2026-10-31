# 商補正候補の通常比較・先行条件

新codecのfull E2Eと独立source/raw監査が成功して凍結された後だけ実行する。正確性証拠がない段階では起動しない。旧Q32の同再開区間での72%拒否を盲目的に再試行するものではなく、新しい商補正実装の比較を1回だけ新rootで行う。

候補は `khc-bwt-causal-bayes-q32-corrected-20261001/candidate.exe`。対照は同じ精度・形式・SA-ISの元Q32 `khc-bwt-causal-bayes-q32-20260930/candidate.exe` SHA FBF35FC6600FB62506658EC63A734F69857489AE2CE53257CD0907D00F6DAD5F。同一sessionのpaired ratioにより商処理の効果を確認する。元Q32の通常時間は過去の静穏拒否で未測定なので、過去速度を推定しない。

凍結 `causal-bayes-q32/compare.ps1` を新harnessへ再利用する。計測helper・observer・gate・順序・native設定は変更せず、candidate/controlラベル・SHA・source/proof参照と同形式frameチェックを更新する。元Q32モデルproof・BWTproofに加えて商のnumeric proof、新full proof、build proofとそれらの全raw/source provenanceをreadlock下で前後照合する。自身と新source/proofをSHAで固定する。

条件は元のquiet-host observer SHA E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF、5回preflightと各child前後<=15%、warmup1+9、3codec循環、全CLI wall、120秒child timeout、1ms要求memory/threadpoll。native7zip26.03 SHA EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0、LZMA2:d=64m/mx9/mmt1/solid、時刻metadataなし。固定group2811006B/SHA18B8...、候補/対照frame483469B/SHA7584...。archive<=483599B、encode<574.5624msは不変。

所有rootは `build/khc-bwt-causal-bayes-q32-corrected-20261001/performance/`、既存拒否/no-reparse/CreateNew。busy拒否/途中失敗は通常時間の成功証拠にせず同じ区間で再試行しない。CPU/priority/affinity/power設定や他processを変更しない。4ネイティブ環境/holdout/総合性/製品統合の勝利とは区別する。Git/version/公開なし。
