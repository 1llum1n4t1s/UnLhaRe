# Forestに限定した整数CDF保証

2026-10-05。独立explorer validated_cdf_proofの読み取り専用結果を親が採取した。調査6ファイルはpacket、paid_model、model、grammar、multi_range、block mod。編集/build/外部資料はなし。まだ検査済み型の実装や速度実証ではない。

Forest::parse成功時は2*142*3*1024=872448行の全てについて、対応k=2,3,4の先頭k要素>=2、tail0、総和32768が成立する。

- model.rs:3-4のGROUPS=3/HISTORIES=1024。packet.rs:174-190のc,node sliceは互いに素で全ROWSを覆う。全モデルとreader末尾を検査してからForestを返す。
- defaultはpaid_model.rs:508-511で1024行fill。uniform→model::quantize([0;4],k)→valid_frequencyで条件を検査する（paid_model:266-267 / model:15-23,71-72）。
- 非default葉は全モードでvalid_frequency後のみ代入（paid_model:418-461）。compact残差もunderflow/型範囲/dominant最低値を検査する。
- S(d,p)={h<1024 | h≡p mod 4^d}。葉のstep_by(4^d)は正確にSを埋める。分割のdigit=0..3とpath=p|(digit<<(2*d))はSを互いに素な4子へ完全分割。depth5分割拒否、depth5葉は1行。根S(0,0)が全1024行なので未初期化行なし。重複代入は非zero sentinelで拒否する。
- high履歴反転は5個の2bit桁の反転で、0..1023上の対合。全子解析後にh<reverse(h)だけswapし、被覆とCDF条件を保つ。
- Forestのfrequency Vecはprivate、構築後の内部可変性なし。lookupは&selfでk範囲を検査し対応群からcopyを返す。別kとCDFを自由に組み合わせない型境界が必要。

重要な例外：paid_model::Dispatchには全群保証がない。parse_rootは3群をzero初期化して指定kの1群だけ解析し成功するが、Dispatch::lookupは他kを受け入れる（paid_model:368-373,481-495）。従ってDispatch全体を同じ検査済み型へ無検査変換してはいけない。

次候補の条件：CDF型のfields/無検査constructorをForestを所有するpacketモジュール内に限定し、kを非公開fieldへ束縛する。zeroのDefaultを作らない。Forest parseが成功した境界からだけ型を生成する。runtimeのunit/rounding gap/切断/normalize/終端/CRCは別の保証なので残す。一般range consumeと任意CDF診断経路の検査は残す。現在は毎branchの検査を維持しており、除去はまだ実装しない。
