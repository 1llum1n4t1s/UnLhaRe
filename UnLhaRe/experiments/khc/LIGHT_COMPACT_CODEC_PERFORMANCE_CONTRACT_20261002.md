# Compact light full候補の正式比較: 実装前契約

新source/EXEの別候補を一度だけ評価する。full51 checks/86 compiler・codec CLI/841 identities、4条件7入力のframe/stdout/restore一致と、実light Prediction24B・outer Prediction608Bを確認した。旧node-u32/compact等のterminal試行は再実行しない。確認待ちの初期化分離は導入せず、凍結観測・計測手順を維持する。

- 固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、11件Canterbury development、旧balanced controlとnative7za26.03のSHA/引数は不変。holdoutとは区別する。
- 新normal241152B/SHA8BA849D4C3122D8F49DF8667D08A0DB497B575F2099EF37B73CD6A911FE04C3E。complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。
- 固定サイズ483599B以下、encode中央値厳密574.5624ms未満、warmup1＋測定9、3codec循環順、single-thread設定、子process120秒、起動前〜終了/stdout/stderr drain後wall、子CPU別。
- 総CPU15%以下、preflight5×1秒と全CLI前後。観測器SHA/初期化位置不変、priority/affinity/power/他processへ介入しない。違反はterminal、同候補を自動再試行しない。
- 出力performance96MiB/親128MiB、現full23958155B、比較見込み48MiB未満。前後disk guard/空き5GiB+予算を要求。EXE/fixture/proofを再利用し、Cargo target/cache/PDB/raw traceを新設しない。既存attemptや出力を上書きしない。

失敗・対応:

1. source/binding混同: 旧node comparer SHA80732F393EA0A5E2EBCA782AC2CB6623373CC8B3ECD40207A0AF2D4B6E9FA333から全文明示対応で派生し、8計測helper ASTを維持。旧node ordinaryは旧絶対path/SHA000670272980C2AA19AC9912611ED15DD43C85DC96D5F5BB64F0FEECF89E25B8/243712へ固定。新light ordinaryを新proofへ別bindingする。旧support pinの相対pathは元ownerを維持してrebasingし、新sourceを追加する。
2. proof/機能の未使用: 新full SHA9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BD、51/86/841、4variant・8期待拒否・frame、heavyイベント3223156/kernel12892624 group/fallback0/Node12B、light24B/outer608Bを照合。数値state proof SHA99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109Fの7/9/15、4summary、mapping1114112/state131072/72値、拒否・継続件数、fingerprint d47b3bd91aab06f7も照合。診断EXE/TLSを正式計測しない。
3. 歴史証拠の破損: 旧comparerの全pins・全検証・全history closureへ新full/light stateを追加し、現在fileを再hashする。numeric wide/narrow budget guardの厳密owner/path/role/旧SHA・長さ→修正済みSHA・長さの限定例外2件だけを維持。preflight/source事前確認とhistory closureの実行状況を区別する。
4. 復号/非決定性/計測失敗: 初回・最後の6decodeとnative SLT、他archiveの初回SHA完全一致を維持。CPU/timeout/CLI/復元/容量違反はattempt/reportへ保存。warmupや未完了roundを中央値へ読み替えず、別sessionの旧warmupとの比を改善率としない。
5. 完了の拡張: 仮に通過してもWindows x64 development encode/total frameの比較だけ。native11fileと候補1groupは異なる復号境界。holdout/カテゴリ・同境界decode・四native決定性・製品/API組込みと安全性が未証明ならgoalはactive。型サイズから総RSS/速度勝利を推論しない。

全環境/argv/source/EXE/proofの識別値、各roundのwall/CPU/memory/threads、前後SHAと最終容量を記録する。計測helper・回数・ゲート・時間境界は変更しない。
