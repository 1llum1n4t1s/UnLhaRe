# Q15優勢shortcutの正式比較: 実装前契約

前goal turnはPROGRESS。旧コードと5920979件×2設定の実比較、新通常/checked完全codecの32項目E2E、元と同じ483496B frameを確認し、次の行動は新候補の一回だけの正式比較となった。goal全体の達成は未証明。前integer試行のCPU16%停止はterminalで、再開/自動再試行しない。

## 固定条件と予算

- 入力KHSGRP0 all.group 2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、11件Canterbury development manifestを使用。holdoutとは別。
- 新binary A98326FBF88608DACE22D44DF934DF5EC3062AB684E934F644013024E69B0FBE、238080B、frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。旧balanced controlと7za26.03は前契約のEXE/frame/全optsを保持する。
- 三codec circular順、warmup1+計測9、CLI開始〜終了/stdout/stderr drainを含むwall、子CPU別、各process120秒、quiet preflight5回×1秒・各CLI前後総CPU<=15%。priority/affinity/power/他processを変更しない。違反/失敗はその試行でterminal、同候補自動再試行なし。
- 完全frame上限483599B、encode median<574.5624msは維持する。decodeはnative側11fileと候補1groupで境界が異なり、総合decode勝利や採用判断へ使わない。
- 元integer comparer SHA1BB00E71EB54CDDDAAC5146C5DC36F43B6F23F8FC37A9F0B5F1D3F546E800B51の8measurement helperはAST本文を不変とする。変更は新source/binary/proof/label/root/予算/追加proof検証のみ。
- performance生成先は既存新codec親のperformance一回だけ、128MiB予算、空き5GiB+予算を前後確認。10round×3decodeは84.34MB程度、archives15MB未満、snapshot約5.63MB、report余裕を足した見積り120MB未満。EXE/compiler/Cargo target/raw trace/ETLは新設しない。

## 失敗条件と証拠

1. 新候補と旧proofの取り違え: 旧integer/proofをそのまま保持し、旧ordinary bindingは旧binary絶対path/SHAへ固定する。新ordinaryは新full proofのnative-codecレコードに別途binding。旧32/53/141と新32/53/218を混同しない。
2. 数値CLIの期待拒否を障害/成功へ読み替える: 新numeric proofの7callはunexpected引数2のみexit2、それ以外0。全5920979record要約が2実行で一致したことを照合する。
3. 計測定義の変更: 新comparerを元から明示置換で全文照合し、8helper AST一致を実行前に要求する。round/order/median/quiet/単process設定/optsは変えない。
4. pinsと現在ファイルの不一致: 元の歴史proof全閉包も再hash。元wide/narrow numericのcapacity guard旧SHA→StrictMode修正済みSHAだけは前契約の厳密owner/path/role/両SHA/長さ対応2件を維持し、他の不一致を許さない。
5. CPU静穏違反/timeout/CLI拒否/非決定frame/復元不一致: failed report/attemptに留め、中央値・対比・採用を成立させない。warmupを9回medianへ読み替えない。
6. 容量/既存output: 出力上書きと既存attempt/root再利用を拒否。開始/終了budgetを記録。用途済みの未参照一時物だけを安全条件に従い片付け、固定証拠やEXE/sourceは保持する。
7. 通過しても評価範囲を拡張しない: Windows x64 developmentのencode採用候補と、holdout/カテゴリ/同境界decode/四native決定性/製品API安全性を分ける。全要求の現在証拠が揃うまでgoal completeにしない。

新source/pin/proof identity、CPU/OS/PS/rustc/script絶対pathと更新UTC/CWD/power、実CLI argv、round別計測、全保持hash、最終容量/processを成果物に残す。
