# 固定窓の悪化原因を調べるtoken形状診断

2026-10-06。v2 screen失格（536620B、15.1666%増）。構成を調整して再試行せず、同v2 encoderに整数counterだけ足し、全frame bytes再一致を必須とする。greedyの探索/tokenizerは同root4rep/32chain/global64*rawと同greedy順序で別再生し、probabilityに依存しないmatch選択のshapeを調べる。旧bitstreamを新たに生成するproofではなく、モデル更新/rep保持の違いも原因候補に残す。

hist index1=literal、3..15=各match長、16=16以上、17=全matchが覆うbyte、18=distance16以下match数、19=比較数、0/2予約。新Profileを外せばfrozen beam_lz_v2.rsにwhitespace正規化一致、全11新frame536620B・旧465951B、全finite/abnormalを再検証。既存source/report/EXEを上書きしない。元1%size gateは失格のまま、sweep/adoption/速度主張なし。8MiB/work/64MiB helper/512MiB compiler/60s child/free5GiB、source追加約70KiB/新EXE約1.4MiB、raw/frame disk0。

