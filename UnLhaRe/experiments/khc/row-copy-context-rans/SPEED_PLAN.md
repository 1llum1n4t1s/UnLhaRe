# 全費用paired速度の事前固定条件

2026-10-07 JST。size/実codecE2E合格後だけ実行する。まだ速度の実測・合格はない。

known development11入力、同EXE/worker1/RAM64MiB、各入力双方warm1＋paired9、全encode戻るまで（現baseline試行、2scan、全CDF/model保存、rANS journal/finish、CRC/wrap）と全decode戻るまで計時。全frame/全復元byte反復一致、public baseline一致を測定外で照合する。

normalの11 median和encode<=現baseline1.10倍かつdecode<=現baselineを必要条件とする。失格なら逆順/係数sweep/移植なし。normal合格時だけ別root・逆順9pairでも同条件を要求する。rateはframes+444+256<=457415を両runで維持。size/E2E report SHAを固定し、共有必須source/依存のSHA/bytes/mtimeをspeed開始前にも全照合する。以前のrunner同一性漏れを再利用しない。

これはKHC現実装に対する局所gate。原GOALの強7Zip以下encode/decode両時間/同メモリ＋5%total小、真正未見、archive native全費用、Zstd、4native統合は別の必須条件で緩和しない。近い既知技術の組合せで新原理/総合勝利を宣言しない。

同じ8MiB/128KiB/64MiB(helper/論理codec)/512MiB(compiler)/60s(child)/300s(suite)/quietCPU15%60s/free5GiB+8MiB/Cargo固定cap、raw/frame/trace/PDB/download/新target/削除0。source/report/EXEは小さい再現証拠として保持。
