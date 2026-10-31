# KT small-denominator reciprocalは補正なしでも厳密

前段feasibility SHA `C2A68C3788E069C277097B1C24CF1546BA9DF3595EAA40DA3817BA09DADD9E9D` の一般ceil-reciprocal商は最大1過大で補正を要する。しかし本件のKT domainと固定cap65536では、更に強い前提から補正が不要と証明できる。元のfloor商、counts/error/モデル/wireは変更しない。

Q=2^32、B=Q^2=2^64、2<=d<=2^16、検査済みKTのn=Q*zero+Q/2<Q*d、R=ceil(B/d)。Rはu64に収まり、u64×u64の積はu128へ正確に収まる。

0<=R-B/d<1より、増加量δ=n*(R-B/d)/Bは0<=δ<n/B<d/Q<=1/d。n/d=floor(n/d)+r/d、0<=r<=d-1（整数残余）なのでr/d+δ<(r+1)/d<=1。従ってfloor(nR/B)=floor(n/d)が全許容域で成立する。d=65536でd/Q=1/dでもn<Q*dなので増加量はstrictに小さい。near-integer、exact-divisibilityも含む。

この証明は任意のu64入力やd>65536の補正省略を認めない。適用範囲を変更したら無効である。d=1はequal fresh nodeのshortcut、d=0は発生しない。checked zero+one overflowとMAX_OBSERVATIONS capを先に検査する。

実分布proof `build/khc-q32-kt-denominator-counts-20261001/report.json` SHA `5EA832E691142C9B1853DEC25BD3A6948A0F9E588344F934DCD587D84E861EFC` はbins `[11671008,8375556,23523717,34034130,50299590]`、商計算127904001中table域77604411。lookup候補約60.67%で、速度削減率ではない。equal shortcut1680505は含めない。9CLI/29identities/旧7scalar/class一致/3frame全byte/復号/反復/既存出力保持/tmp0を確認した。

新numeric段階では商だけでなくtable使用/reciprocal値も独立BigInteger oracleへ照合し、全d=2..65536とzeroの境界/中間を列挙、旧KT65536recordsも保持する。compiler生成コードのhigh multiply/lookupとtable初期化費用は後段で確認し、数学・件数は速度採用と区別する。
