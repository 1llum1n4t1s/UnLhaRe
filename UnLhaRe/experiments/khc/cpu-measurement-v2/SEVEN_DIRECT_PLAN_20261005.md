# 直接parse版対7-Zip：全development再評価

2026-10-05。DIRECT_PARSEの旧新paid/low自己・相互復号、完全frame互換の確認を先に完了する。新direct EXE SHA256 87D22FCD6E500BCBB26371BC4B86C19208796C36D6D596F7E89D18CFEB9C115C、既存7za SHA256 EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0。7-Zip26.03の公式確認は同日SEVEN_EMPTY記録を参照。バージョン・argv・サイズ・SHAをrunnerもpinする。

GOAL_GATEは変更しない。固定Canterbury全11file＋5境界生成入力、16fixture、warm1＋9順序交互、640native/320自己復号、別形式なのでcross0。各file全体を使う。モデル/header/CRC/終端込み総サイズ、process起動・I/O込み時間、64MiB WS/privateを測る。9中央値のfile合計はsolid/batch中央値ではない。短命private peakの観測制限は保持する。

7-Zip LZMA2/XZ mx9/mmt1/md4m/mfb273、dict4MiBは各入力最大1MiBを覆う。paid KHCを比較する。全入力manifest/pin、原byte完全一致、全pin前後一致を要求。過去empty/leaf時間を混ぜず、今回の対応測定だけを集計する。developmentなので未見評価とは称さない。

CPUquietを含むsuite900秒の維持のため0..4、5..10、11..15の互いに排他的な3区間で実施。各区間最大256KiB報告/8MiB作業先、5GiB空き、子60秒/64MiB、raw/frame disk0。各状態の成功を確認して次を開始する。実測失敗は再実行で消さず残す。追加build/downloadなし。総新JSON上限768KiB、既存tool/corpusを再利用する。

direct改善を7-Zip突破と取り違えない。率優先なら全体467761 B以下かつ7-Zip以下の時間・RAM、速度優先なら7-Zip以下のサイズかつ圧縮・展開10%以上短縮、さらに独立未見評価/反復を要する。未達なら大きい不足を次候補へ戻す。
