# 次のinverse候補：LFが置換であることを利用できるか

packed23の一設定実行は全復元・拒否・境界比較が成功したが、同EXE限定中央値49.6452ms、順別38.8993/53.10115msで正式展開条件への到達は未証明。再実行して良い値を選ばず、別の仕事量削減をコード前に検討する。これは未実装の親による数学的導出であり、実測・採用証拠ではない。

## 明示的な置換の証明

symbol s のcountをc_s、prefix startをa_sとする。構築時に同じsymbolの各出現へrank0..c_s-1を一度ずつ付けるため、LFの行先は連続区間[a_s,a_s+c_s)を重複なく埋める。prefixがcheckedで、count和がn、全symbol範囲が確認されていれば、全symbol区間は[0,n)を分割する。したがって構築済みLFは全行の置換である。この事実は任意の外部next配列には適用しない。

置換の軌道は開始primaryを含む一つのcycleであり、primary以外を先に再訪することはない。よってstep0を除きprimaryへの早い帰還を拒否し、n回後にprimaryへ戻ることを確認すれば、cycle長は厳密にnで全行を一度訪問する。visited配列/各wordへのmark書込みを省略しても、短cycleや重複訪問を許可することにはならない。単なる終端primary確認だけではnの約数長cycleを見逃すので、早期primary拒否は必須。

## 一候補の範囲

u32のbits0..23をnext、24..31を元byteにする。visitedを格納しないため24bit indexになり、private max n8388609もpackedに収まる（出荷済み上限変更ではない）。構築中のcount/prefix/rank/range、sentinel1/alphabet、primaryを維持。walkerはwordをread-onlyで読み、step>0の早期primaryを拒否して逆順plainへ出力、n回後のprimary帰還を要求する。markのrandom writeとそれに伴うcache ownership取得をなくせる仮説だが、CPU効果は未測定。

## コード前の反証項目

- LF構築が置換になる前提を外部入力が破れないか。全symbol/checked和/row範囲/occurrenceの数え方を確認する。
- 短cycle長1/2/3、nの約数長cycle、primary以外の不正symbol/alphabetを拒否する。nだけ歩いて終端を確認する誤実装を区別する。
- plain empty、0/255、全byte、反復、決定的非反復を元BWT/reference/新方式で全byte比較。
- private上限直前/一致と上限超過をRAMだけで確認し、24bitのmask/byte最大も小handで検証。MAX_N+1拒否は共通wrapperの契約と区別する。
- 既存packed23は凍結し、別root・単一設定・同EXE比較。計時/資源/全CLI条件を緩めず、現在の49.6452msや3秒のpayload時間を新方式へ転用しない。

これはinverseだけの新候補であり、payloadの数秒問題やencode・holdout・完成書庫/API・4nativeを解決しない。今回の候補を実装する前に失敗計画・source所有権・親テストを確定する。

親の限定設計チェック：JavaScriptでn1..8、sentinel位置全通り、他symbol1/2の全通り1793件をRAM列挙。LFの全行先が重複なく[0,n)を埋め、visited式とearly-primary＋終端primaryの受理が全件一致（受理255/拒否1538）。これは小有限領域の補助確認で、Rust/native/E2E実行や速度測定、任意入力の証明の代わりではない。上記の一般的置換導出と将来のnative反証を分けて保持する。
