# Flat-token CDF：実装前の小規模検証（2026-10-07 JST）

現native RecordTrialは既知11入力でarchive457017B対最新7zip26.04 481490B（5.0827%小）だが、normal9pairsのfull verify median87.5501ms対43.0739msでdecode gate失敗。source/reportは保持し、defaultにはしない。旧方式の係数調整や失格の再解釈ではなく、MDL token全体を別wireの1 intervalへflattenする候補を検証する。今回の変更はprivate arithmetic witnessだけ、native/wireの既存仕様には触れない。

## 根拠と新方式
固定grammarはchild token範囲を順序連続に分割し、最大depth8。rank/length tokenのsupport N=limit<=257。開始時のcomponent別history3個（各10bit）を保持し、chosen path上の同class再訪・k1も履歴更新する。sibling内部の条件確率総和は1なので、そのsubtree massに内部履歴を列挙しなくてよい。
D=2^120でnode mass A、先行mass Bを保持し、branch cum g/freq fへ B'=B+(A>>15)*g, A'=(A>>15)*f。scale15×depth8なので最後のbranchまでAはshift15で割り切れる。先にA*fを計算すると135bitとなるためshiftの順序を固定する。
Q=2^18、M=Q-N、leaf前のmass P_iから C_i=i+floor(M*P_i/D)。各leafに最低1を割り当てC_0=0,C_N=Q、全freq>=1となる。これは旧branch streamとwire同値ではなく、新形式側だけへ適用する。旧range MAX_TOTAL81920はQを拒否するため、別backendが必要。旧backendの上限を黙って変更しない。
P=P_hi*2^64+P_lo、t=P_hi*M+high64(P_lo*M)としてfloor(P*M/2^120)=t>>56。tは74bit以下なのでRust u128で保持できる。138bitの全積は作らない。P=Dも合法。
cacheはforest単位でresetし、component+limit+開始history3個の完全keyと直近leaf interval/symbol/終了historyを持つ。encodeはsymbol一致、decodeはslot∈[cum,cum+freq)も条件とする。65536cells×24B=1.5MiBは配置案であり、hit率と性能は未測定。leaf分布全列挙／全context CDF事前生成は512GiB規模となるので採用しない。

## 失敗先行と今回の上限
今回コード前に固定：N0/>257、P>D、M不整合、ordinal>N、empty/逆転interval、mul overflow、CDF終端/単調/正freq、partial depth/state、support境界、全積を先に作る誤り。独立oracleはu128のbinary double/add/divide（最大3D<2^122）で表現し、wide shift実装とは独立に照合する。親V8 BigInt 32境界照合と探索担当のPowerShell BigInteger 28境界照合を先に成功。これらは速度やnative採用の証明ではない。
Rust standalone有限E2E witnessを先に作り、small JSONを保存。新unit testなし。最大専用output1MiB/report16KiB、既存rustcのみ・依存0・Cargo増分0、free5GiB+1MiB、compiler512MiB/60s、child16MiB/10s、CPUquiet15%/60s。raw/frame/trace/download追加0、source/小EXE/reportのみ保持。
整数witnessが通過後にのみ、旧grammarの実corpus token context cache hit率とpaid metadata/rate censusを別工程で行う。coder/prototypeを先に大きく作らない。実測costが改善しない場合は打切り。GOAL active/未達、quantum研究の未採用方針と同等以上rate/速度/RAM/未見・Zstd・7zip gateは変更しない。

