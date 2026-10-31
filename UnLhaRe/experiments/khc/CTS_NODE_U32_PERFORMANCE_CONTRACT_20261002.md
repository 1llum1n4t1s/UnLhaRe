# CTS node-u32候補の正式比較: 実装前契約

node-u32は新しいsource/EXEの独立候補。full E2E 55 checks / 94 compiler・codec CLI / 550 identities、4条件の状態・境界検証とfull圧縮/復元、実Node12Bを確認した。旧compact候補のterminal試行は再実行しない。確認待ちの初期化分離も導入せず、凍結済み観測・計測経路でこの候補を一度だけ評価する。

## 固定ゲートと予算

- 固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、11件Canterbury development、native 7za26.03と旧balanced controlのSHA/引数を維持。holdoutへ読み替えない。
- 新normal243712B/SHA000670272980C2AA19AC9912611ED15DD43C85DC96D5F5BB64F0FEECF89E25B8。固定complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。
- サイズ483599B以下、encode中央値厳密574.5624ms未満、warmup1＋測定9、3codec循環順、single-thread設定、子process120秒。wallは起動前から終了/stdout/stderr drain後まで、子CPUと区別する。
- 総CPU15%以下、preflight5×1秒と各CLI前後のゲート、観測器初期化位置も不変。priority/affinity/powerや他processを変更しない。失敗はterminal、same candidateを自動再試行しない。
- performance出力96MiB、full親128MiB、実行前後のdisk guard。現fullは24581103B、比較見込み48MiB未満。固定入力・既存EXEを再利用し、Cargo/cache/巨大raw/PDBを新設しない。既存attempt・出力は上書きしない。

## 失敗・対応計画

1. 旧candidateとのbinding混同: 元comparer SHA1BE81D1A34C8CDACDA75550C68F49ED3A2CA86AF3E1DFA8D256F8D0C5BF53C80から全文明示置換で派生し、8計測helper ASTを維持。旧compact ordinaryは旧絶対path/SHA362282160B038EF495927DE2F855E8EF651D4611101BA8D8D0F842AA8D61DDB9/243712へ固定、新node ordinaryを別にbindする。
2. 新proof/機能の未使用: full report SHA9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04、55/94/550、4variant、8期待拒否、frameと診断を照合。状態4summary各65644 transitions/131072 events/85値、9 storage cases・3拒否、invalid class4拒否＋継続1、fingerprint0dc7c1e133772fd7を要求。Node12B、917497 nodes、論理領域11009964B、kernel12892624 groups/None0を確認する。診断EXEは計測しない。
3. 歴史proofの破損: 旧comparerの全pins・検証・全history closureを残し、新proof/sourceを追加する。numeric wide/narrowの予算guardの厳密owner/path/role/旧SHA・長さ→修正済みSHA・長さの例外2件だけを維持し、他の不一致を許容しない。preflightとsource事前確認、実行後のclosure検証状況は区別する。
4. CPU/CLI/時間/復元/非決定性/容量違反: attempt/reportへ残し、途中値やwarmupを中央値へ読み替えない。初回/最後の6decodeとnative SLT、他archiveの完全SHA一致を維持。復号境界はnative11fileと候補1groupで異なり、総合勝利の根拠にはしない。
5. 範囲超過: 成功してもWindows x64 developmentのencode/total frame比較だけ。holdout/カテゴリ、同境界decode、四native決定性、製品/API安全性と組込みが未証明ならgoalはactive。RSS改善や速度改善をNodeサイズだけから推論しない。

全argv/環境/識別値、round別wall/CPU/memory/threads、前後SHAと最終容量を残す。固定ゲート・計測回数・出力境界・helperは変更しない。
