# root履歴順の独立反証

独立analyst（gpt-6.1-sol/medium）へ同じ費用課題の継続読み取り監査を委任、指定6資料のみ、編集/compile/native/Git/外部/削除0。親が実コードと費用計上を確認し、低位/高位固定2候補のsplit root選択だけ採用判定した。全120順、node可変順、精度/幅sweepは範囲外。

- grammar履歴更新((h<<2)|child)&1023は低位が最新。high-firstへの一括移行はh&1依存を深くするため棄却。現h>>8 fixtureのlow-first深木341split/4437bitに対しhigh-first浅木は17bit。有料split root feeを含む両方向は4438対18、最新依存は逆。元history全1024を五digit反転Rで同じ意味へ復元できるが、効果は実入力未測定。
- 新root split費用2bit、内部split1bit。旧Fit決定後の事後+1はleaf/split選択境界を変えるので不可。選択root leaf/defaultにはorder bitを保存しない。両順のroot loss+実bitsを比較し同値low、root単位prefix混在を許可する。
- 新wireはroot splitbitの直後のみorderbit、元global wireと非互換。hist ingest/high Fit lookup/reader履歴maskは同じRを用いる。完成Forestのindexは元history。原grammar/Dense/freeQ/quantize/CDF生成を変更しない。
- 元explicit300個以下への同木追加orderbitは最大38B（実際はsplit根のみ）。改善保証ではなく元不足3945Bを払う新費用screenが必要。hist＋fit各1組追加のheap概算196608B、既存model約30.37MBに加算しても32MiB内見込み、実sizeof/capacity/peakで検査。学習と検証両順Fitで1112build、元556の2倍。Dense/Forestは増えない。
- 独立1024置換/逆、対称依存fixture、prefix混合、leaf/default無課金、DP境界、truncated order/深度/pad/trailing/回復、Fit→個別root→完成Forest全CDFとloss/Meta一致が必要。size通過でもteacher0/state未検証/frame0のscreenは完成codec・速度を証明しない。

Performance/Hardening/Testerを担当。Modernizer/Normalizer/Cleanerは今回依存更新・方式混在整理・削除の変更なし、Intel/Startup非該当。Asyncは親の有限同時保持・明示drop/capacity・プロセス終了の範囲で確認する。opop全基本観点を限定scopeで追跡、製品の全体監査ではない。

親追補：k2のh0にchild0を8、h1にchild1を8の2rowだけ入れるとuniform root loss16bit。旧low split fee15＋tiny purelossは16未満、新fee16＋tiny lossは16超過なのでdefault葉へ戻る。これを先行固定境界とし、workerはparent/child整合Histで算術を検証してから実装する。

親PowerShellの非書込独立算術（compile/native0）は1024置換値のuniqueとR(R(h))=h全件成功。pure16イベント損失0.00140892487328bit、旧split費用込み15.00140892487328<uniform16、新16.00140892487328>16。深木有料費用341+1024*4+1=4438、浅木2+4*4=18を確認。これは境界算術だけで、候補Rust/実入力/速度検証ではない。
