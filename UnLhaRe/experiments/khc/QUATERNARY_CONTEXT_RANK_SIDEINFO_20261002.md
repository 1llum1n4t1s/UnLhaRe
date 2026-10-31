# 4分岐診断の既知rank情報追記（実装前）

元契約C480B08D4D3A5934B6D461BAB17BCC7252F2D0698FD5CE005FCE6B6CA8E06F26は保持する。実装・compile/runはまだ0で、次の修正を実装前仕様へ追記する。

lengthでは同じrunのrankが既にdecode済みであり、凍結direct codecもlength keyにexponent(rank+1)を使用する。この既知情報を新候補から落とす理由がないため、元契約末尾の「length predictionへ既知rankを反映しない」を置き換える。

- rank componentではrankContext=0。length componentではrankContext=exponent(rank+1)、範囲0..8。
- nodeKey=(component<<31)|(rankContext<<20)|nodeId。symbol/recent/joint全expertのhash keyにこの既知rankContextを含める。
- global row index=(component*9+rankContext)*256+nodeId、計4608rows（元512rowsから置換）。mix weightsも同じglobal rowで保持し、別rankContextを混ぜない。
- 現在runのrankが確定した後にlength全digitのpredictへ渡す。recent/previousの更新は依然run完了後であり、未来情報は使わない。

他のtopology・expert count・fixed share・出力・予算・停止条件は元契約のまま。全token/limit traversalに加えrankContext0/8・invalid9を独立検証へ含める。元SHA・旧proofや計測済み候補は変更せず、両契約を次のsource/import/run identityへpinする。
