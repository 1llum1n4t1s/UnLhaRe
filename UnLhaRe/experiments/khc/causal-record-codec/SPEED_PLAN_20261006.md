# KRC1 size通過後の固定paired screen

2026-10-06。screen-aで全frame437580B、全費用予約438280B<=457415Bを確認したため進む。codec/voter/context/設定を変更せず、同processで現Program baselineと新codecのnormal入口を実行する。observer診断を計時へ混ぜず、encodeは新旧両試行・voter・40B包み・CRC・stored/fallbackを全て含める。

入力ごとに双方warm1、その後9回交互。各file中央値を合算、median/min/max/9配列を保存。全sampleのframeは既知size/sourceと反復byte一致、decoは元raw全byte一致、論理64MiB/child64MiB内。旧baseline frameはpublic encodeと完全一致。metadata/bodyだけのサイズやcodec内部一部だけの時間で判定しない。単独block合算の局所screenで、新native archive/7-Zipとの勝利ではない。

評価前local採否：新全11encode中央値合計<=旧の1.10倍、新全11decode中央値合計<=旧、各file decode増分・率/時間を全開示、全frame437580B不変。normalが失格なら逆順の速度/後付け係数/距離/context sweep/製品移植なし。normal成立時だけ同source/EXEで逆順を実行し同条件再現を要求。これは局所前進条件で、最終のGOAL_GATE_20261005.md（率5%かつ**7-Zip以下のencode/decode**、又は率同等かつ両方10%高速、真正未見・両順・全費用・全memory）を緩めない。

2026-10-06公式 [Download](https://www.7-zip.org/download.html) と [History](https://www.7-zip.org/history.txt) 本文を再確認、現行公開最新版26.03/2026-09-03。既存frozen強solid基準481490Bと同じ版で、今回は新download/差替えなし。現在版の確認と今回新性能比較は別の証拠。

専用root8MiB/report128KiB/free5GiB+8MiB、compiler512MiB/helper64MiB/child60秒/suite300秒/CPU15%静穏60秒、Cargo固定cap/raw/trace/PDB/newtarget0。原GOAL active、旧候補/失敗source/report/EXEを編集・削除しない。
