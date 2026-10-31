# Hamilton選択の先行失敗計画（2026-10-04）

上位 QUATERNARY_CTS_HAMILTON_PLAN_20261004.md を正本とする。新root7files、source300KiB、output8MiB、EXE1MiB、report256KiB。

- 旧depth CTSを機械複製。kt/normalize_q2の選択2ブロックのみ変更。left0順位なし、left1 child昇順strict greater、left>=2元sort。guards/increment/数学・sealed snapshotを維持し逆復元allowlistを照合。
- KT17320（正常17262/拒否58）、mixture4137（正常4126/拒否11）を全vector/masses/error直接比較。mixture6directedでleft0/1/2/3/max tie、24prefix/weight境界、4096決定的系列。invalid weight>own>childの競合字面と順を確認。
- codec型スコープの旧/新model各(14,16,1)、CTS正常/修復後受理4、stale/derived/unused-tail拒否6で全状態維持。
- 固定ABBA old/new/new/old1周、encode/decode各4、warmupなし。478750B全frame3回、2811006B全plain4回、Proof14/stats22全要素（CDF bits）比較。両方向median短縮だけ次段条件、正式CPU/7-Zipは未検証、好結果狙い再試行禁止。
- compile60s/contract60s/ABBA120s、stdout64KiB/stderr16KiB。所有childだけ終了、output既存拒否。Cargo/PDB/rawtrace/frame/plain/input生成なし。
- inner report SHA59C4C8B73DF3275303D52629C3862CD1F83D260AF60EC9E4D8A024AA95571562、215identities＋report/EXE＋新source7で224identities。pins前後/liveとsourcegraph閉包。

worker新rootのみ、親計画/結果/native。Git/外部/削除/追加委任なし。

