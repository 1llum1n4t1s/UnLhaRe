# 現codecの跨file境界：有限size診断

2026-10-06。rANS通常順が事前15%screenを満たさず不採用。current archiveはentryごとに1MiB blockをresetする（src/khc/mod.rs create loop、KHC_FORMAT）。現モデルを変更せず、固定Canterbury manifest順に全11本文を連結し、1MiB×2+713632Bへstream packingしたときの実frameサイズを調べる。新形式や公開APIをまだ作らず、既存public compress/decompressを使用する。既試行のdirect model、4state backend、CDF検査削減は再演しない。

構成は既存MdlとBinaryAdaptiveの2つだけ。3block各々で両者を一度圧縮し、全byte復元を確認。順番変更/サイズ変更のsweepなし。これはサイズと機能の診断で時間比較ではないので、CPU静穏を性能条件から外した再測定ではない。高負荷中でもchild60秒/RAM80MiB以内の一回実行、計測時間で優位を主張しない。

現native466395B、frame465951B、native7z481490B。現費用444Bのうち11frame prefix44Bを3prefix12Bへ変えた412Bを仮想container下限とする。CRC/manifest/name/mtime/header/end費は消さない。新solid拡張の費用は未仕様なので、追加256Bを別に課金した668Bも併記する。これは実native書庫サイズではない。5%ゲート457415Bを超える場合はsolid packingだけでサイズ条件を解消できない。通っても速度/未見/安全性/真正archive/4nativeが未達で、製品採用資格を意味しない。

失敗先行：inputサイズ/SHA/pin変更、EOF不足/余分、raw合計2810784不一致、block3でない、frame header宣言/raw照合失敗、自己復号全byte不一致、配列/長さ/overflow、allocation/child timeout/RAM超過は失敗。空/1B/全256入力のpublic両strategy往復を先に実行する。stdin/raw/encoded/journal traceのdisk0。frameはchunkごとstrategyごとにdropする。source chunk1MiB/encoded上限1MiB+40/plain1MiB＋codec予約64MiB＋runtime余裕8MiBを見積り、80MiB process guard。compiler512MiB/60s、全suite180s、新work8MiB/ソース50KiB/report128KiB/free5GiB、Cargo0、current rlib・全src/khc/CRC/compiler/native lib/host macro/corpusをread lock+SHAと終了検査。EXE/PDB2MiB見積り、report以外のdata生成なし。

親がsource/runner編集と実行を所有、新agent/外部write/Git/x86/version0。事前budget/事後budgetを実施。新PDBが生じた場合は用途終了後共通helperで今回分だけ清掃する。GOAL active、元ゲート不変。
