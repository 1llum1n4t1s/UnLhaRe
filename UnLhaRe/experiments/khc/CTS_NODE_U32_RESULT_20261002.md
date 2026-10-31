# CTS node-u32の結果

状態の保存幅だけを変更した候補は正確性・サイズ検証に合格。Nodeの論理領域は25%小さくなった。速度と総合7-Zip超えは別の正式比較結果を参照する。

## 正確性と互換性

- full report: `../../build/khc-cts-node-u32-20261002/report.json`、316593B、SHA256 `9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04`。
- UTC 2026-10-01T19:42:17.4119718Z〜19:43:05.5359797Z、55 checks / 94 compiler・codec CLI / 550 identities、status `correctness_and_size_passed_not_timed`。
- native/scalar×overflow-check有無の4条件、各7入力でframe・stdout・復元一致、旧decoderとの双方向互換、破損5種・no-clobber・missingの拒否を確認。
- 固定complete frame483496B、SHA256 `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`。上限483599Bを維持。

各状態CLIは65544 transitionを旧・新helperと独立u128式で直接比較。checked保存9境界例中3件を拒否し、拒否後の保存状態不変を確認した。7class・131072イベントで毎回85個のpath値を旧モデルと直接比較し、class拒否4件とその後の正常継続1件も一致。4条件の全summaryが同じで、fingerprintは `0dc7c1e133772fd7`。raw数値列は保存していない。

全562036803観測位置を総当たりしたわけではない。合法範囲全体の安全性は契約の解析に依存する: alpha≥7、retained=Q-2alpha≥0、posterior≤Qよりnext≤Q-alpha≤4294967289。有限境界・固定seed標本はその実装を検証する証拠で、解析の代用ではない。保存時のchecked変換は保持し、任意の範囲外private状態を旧モデルと等価とはしない。

## メモリ領域と実使用

旧Node16B→新Node12B、Prediction544Bは不変。917497 nodesの論理領域は14679952B→11009964B、差3669988B（約3.5MiB）。allocator overhead、light tree、journal、総RSSはこの差に含まれない。モデル全体や製品のメモリが25%減ったという主張ではない。

full診断encode/decodeでもNode12B/論理領域11009964Bを取得。heavy event3223156件に対するcompact kernel使用12892624 group、fallback0、summary/frame/復元は一致。通常EXEには診断カウンターを含めない。

normal EXE243712B、SHA256 `000670272980C2AA19AC9912611ED15DD43C85DC96D5F5BB64F0FEECF89E25B8`。codec・scheduler・exact_ktは元compactと全文・SHA一致、heavy sourceのみ13件の明示対応。verifierは10件の全文対応を照合した。

## 容量・残作業

full report保存後24581103B、32MiB予算内。report内のbudget_after24264510Bはreport自身の保存前の値。PDB/tmp/reparseなし、固定fixture・compiler再利用、Cargo cache/target・raw dumpは新設していない。

旧terminal候補は再実行せず、観測器・固定ゲート・初期化位置は未変更。新normalの正式比較は別契約で一度だけ実行する。事前guardで旧support pinの相対path7件が新folderへ誤binding/重複する問題を検出し、旧ownerの絶対的に一意な相対参照へ直した。計測前の修正であり、既存source・proof・結果は変更していない。65 pin・8 helper AST・全文対応を確認してから実行する。

holdout/カテゴリ、同境界decode、四nativeの決定性、製品/API組込みと安全性は未完了。製品コード・他版・version・Git・公開には変更していない。
