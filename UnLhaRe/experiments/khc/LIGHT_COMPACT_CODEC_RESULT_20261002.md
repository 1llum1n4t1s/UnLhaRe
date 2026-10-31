# Compact lightのfull組込み結果

圧縮経路への組込みは正確性・サイズ検証に合格。新lightの末端→親走査とtotal/one保存を使用し、符号化仕様・schedule・frame・復元は旧版と一致した。正式速度と総合7-Zip超えは未証明。

- full report `../../build/khc-light-compact-codec-20261002/report.json`、419149B、SHA256 `9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BD`。
- UTC2026-10-01T20:21:20.487672Z〜20:22:08.3140357Z、51 checks/86 compiler・codec CLI/841 identities、status `correctness_and_size_passed_not_timed`。
- native/scalar×overflow-check有無、7入力の全frame・stdout・復元を凍結integer候補と実byte比較。双方向decoder、破損5種、no-clobber、missing拒否も確認。
- 固定complete frame483496B、SHA256 `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`、上限483599B内。

## Sourceと実経路

codec sourceはnode-u32版と全文・SHA一致。schedulerは3件の明示対応のみ: heavyの参照を凍結node-u32へ固定、lightの参照を新モデルへ切替、診断cfgに型サイズを追加。heavy/KT/BWT/range/grammar/Bayes/scheduler学習規則は変更していない。

元full verifierから8件の全文対応を照合し、旧matrix/拒否条件を維持して新source/proof検証を追加。light数値/状態proof SHA99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109Fの7/9/15・全identityと4summary、node-u32 proof SHA9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04の55/94/550・全identityを現在fileと照合し、numeric CLIを重複実行せず再利用した。

full診断encode/decodeは実heavy event3223156件、compact kernel12892624 groups/fallback0、Node12B/917497 nodes/論理11009964Bを確認。light Prediction24B、outer scheduler Prediction608Bも実codec内で取得し、両方向の全診断・frame・復元が一致。診断counter/TLSを正式計測用normal EXEへ入れていない。

normal EXE241152B、SHA256 `8BA849D4C3122D8F49DF8667D08A0DB497B575F2099EF37B73CD6A911FE04C3E`。snapshot sizeは型の値で、総RSS・copy実回数・速度改善率ではない。

## 容量と残作業

full report保存後23958155B（約22.85MiB）、32MiB予算内。report内のbudget_after23539006Bはreport自身の保存前。PDB/tmp/reparseなし、既存fixture/compilerを再利用し、Cargo target/cache/raw traceは新設していない。正式比較のattemptは別に保存する。

正式比較はpreflight CPU32%で終了し、codec/control/nativeのCLI0件。性能結果文書を参照。観測器/固定ゲート/初期化位置を変更せず、同候補を再試行しない。確認待ちの初期化分離は導入していない。

holdout/カテゴリ、同境界decode、四native決定性、製品/API組込みと安全性は未完了。製品/x86/version/Git/公開・共有cache・他process/CPU設定には変更していない。goalはactive。
