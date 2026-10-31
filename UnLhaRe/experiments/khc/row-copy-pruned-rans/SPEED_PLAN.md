# 出力同一encoder pruningの事前速度条件

2026-10-07 JST。先行KRS1のreverse失格を維持して、別encoder（数学的prune）を検証。係数・context・decoder・wire変更0。lower proof-bとscreen-a成功：591344整数不等式、実ANS32768frames/163840limit、full trialとの36＋11全frame一致、prune14実到達、全byte/反復/独立grammar6/4CDF768/1277必須拒否、frames456573/全予約457273B。size source SHA92D03A351B4F68400FA119AA9417DC9B10CB95E69A12B61817C083897008D907を固定し、bound/codec/依存共通hash/bytes/mtimeを測定前後で要求する。

normal両経路warm1＋9交互pairsの11median和で encode<=現baseline1.10倍かつdecode<=現baselineを必要条件にする。失格なら本candidate逆順/係数sweep/製品移植なし。normal合格時だけ同一EXEを再利用して順序反転9pairsの別runで同条件を要求する。両順total457273B/全復元byte一致も必要。

全encode戻るまで（baseline試行・第一scan/4hist/CDF/下界計算/必要な第二scan/rANS/モデル/CRC/wrap）、全decode戻るまでを計時する。判定やfallbackを計測外に移さない。callerは双方同じ3MiB＋160B上限をlogicへ課金、共同process64MiB監視、個別7Zip peak比較と区別する。

原GOALの強7zip以下両時間/同RAM＋5%小、真正未見/native archive/全metadata/4native/Zstdは別必須条件。known block warm比較だけで総合勝利・完了としない。

8MiB/report128KiB/free5GiB+8MiB、helper/codec64MiB/compiler512MiB/child60s/suite300s/quietCPU15%60s、Cargo cap6175228536B/増分0、raw/frame/trace/PDB/newtarget/download/削除0。source/report/EXE保持、上書き前backup。現在はまだ速度未実行。
