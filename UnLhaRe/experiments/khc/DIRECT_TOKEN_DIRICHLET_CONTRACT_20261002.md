# 高精度global/local混合: 次候補の実装前契約

## 根拠と範囲

KHNPR001はframe610222byteで不採用。cold状態診断でP256とalphabet256の一様支持が50%を占める機構を確認した（PRIOR_PRECISION_DIAGNOSTIC_CONTRACT_20261002.md、report SHA8C3A0782986D581AE7BA253CF33D107AE2BD676389FF8F1EDF0475E0BEE7D2B9）。全書庫悪化の寄与分離は未検証。以下は高精度混合による新しい仮説であり、採用・性能勝利を事前に主張しない。

新sourceはdirect-token-dirichlet/に置き、旧source/proofを編集しない。新formatはKHNDR001、range/BWT/packed alphabet/grammar/CRC/no-clobberを継承する。root1/local0初期化、16384でceil-half rescale、keys1..4096/alphabet1..257、prefix全体で丸める方針を維持する。固定corpus/gate/CPU/時間境界は変更しない。

## 整数CDF仮説

Q=32768、lambda=64は本候補で固定する。global total D、local total T、global prefix R(k)、local prefix L(k)から
C(k)=k+floor(Q*(64*R(k)+D*L(k))/(D*(64+T)))。
frequencyはC(k+1)-C(k)、許可prefix limitのtotalはC(limit)。各symbol支持1を加え、全alphabetのtotal=A+32768<=33025（旧range domain81920以内）。coldのuniform fractionは最大257/33025<1%、未学習でもglobal分布を近似する。localが増えれば事前64観測よりlocalが優勢になる。切り詰めたlimitでも同一D/TによるCDFを使い、prefixノードを個別に丸めない。

D1..16383、T0..16383、0<=R<=D、0<=L<=T。
den=D*(64+T)<=269451201（16383*16447）。
n=Q*(64*R+D*L)<=32768*den<=8829376954368。実装時はchecked arithmeticと独立u128 oracleでも境界を照合する。全てu64内、n<2^64。
高速商はm=floor(2^64/den)、q0=floor(n*m/2^64)。den>=64でmはu64へ収まる。
m=u64::MAX/den + indicator(u64::MAX%den==den-1)。
0<=n/den - n*m/2^64 < n/2^64<1なのでq0は正確商か1小さい。n=0では誤差0を別に扱う。余りn-q0*den>=denなら1加算し、q*den<=n<(q+1)*den、q<=Qを整数で検証する。
u128積で高位64bitを得る。逆数構築やu128積が速いと未計測で主張しない。

## query/update責務

preparedDistributionをkey/limitについて読み取り専用で作り、同一CDF/scaleでtotal/interval/selectを行う。lookupはglobal/local Fenwickの累積全体へ同じ式を適用する。query後に借用を終了してupdateする。拒否key/token/limit/slotでcount/stateは変わらない。更新はroot/local両方の事前検証後にcommitし、永続の文脈scale cacheを持たずstale rescale問題を避ける。prepared APIでquery回数を減らしても速度証拠と扱わない。

## 実装前に列挙する失敗

- cold全symbol初期化・alphabet1/257・prefix0/full・limit1/AでCDF端点誤り、positive支持欠落。
- den/逆数/u128積/補正境界・n0・D1/16383・T0/16383の商不一致。
- Fenwick跳躍でノード単独丸め、interval/select不一致、未使用slot受理。
- root/local rescale順、拒否updateの部分更新、query再利用の寿命や同一CDF破綻。
- allocation/keys*alphabet境界、reserve失敗で部分stateや出力を公開。
- grammar/varint/active symbol/終端/CRC/BWT cycle/no-clobberの退行。
- source/import/EXEの途中変更、予算超過・raw trace・Cargo/PDB生成、旧candidate再試行。

## 独立検証と容量

先に実配列・通常u128除算・線形slot探索のoracleとの数値/state照合を行う。少なくとも前候補の393216イベント、root/local再scale、invalid拒否、cold/hot witnessを含む。denの全数走査はしない。D/Tの端点、閾値直前後、seeded組合せ、Q出力境界ceil(q*den/Q)の前後をbounded streamingで検証する。実際のFenwick queryをoracleと比較し、checksumだけの正確性主張をしない。opt2/3×overflow yes/no、全4 stdout一致。

fresh build/khc-direct-token-dirichlet-model-20261002、8MiB cap/約1MiB見積り、4小EXE+小reportのみ。source/compiler/runtime/readlock/import/前後identity、120s child・stdout/stderr65536文字・report512KiB、debuginfo0 /DEBUG:NONE、Cargo/PDB/raw traceなし。出力前に個数×reserveを確認する。既存rootへの上書き・同条件自動再試行はしない。範囲拡大が必要なら先に報告する。

数値証明成功後だけfull E2Eの独立契約を保存して実行する。新fullでも7入力×4条件、全byte/wire比較、独立forgeと拒否、旧format拒否を継承し、大きな中間を逐次比較後削除する。fixed input全frame<=483599byteが必要。サイズ未達なら正式性能を起動せず判定を保存する。goalはencode中央値574.5624ms未満/CPU15%、同境界decode、holdout/カテゴリ、4native、製品/API安全性を含むまま未達。Git/version/公開/x86/共有cacheは対象外。

