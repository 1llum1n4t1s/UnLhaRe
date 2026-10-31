# causal direct mix：一設定failure-first

設定は親planに固定。初稿SHA6AF6851C016E101BEE2A55CB8EC2756BA58DDFE63DD069E9F257BA8B472BB684を読み、RAM算術訂正を含む最終SHA A7D8FBD4C5BDEFFFD77511946B53BCE245AE17C9533BA70059D15B901253B5CCを実行前に再読・固定した。実coder/frame/復元/速度/製品採用ではなく、因果count算術混合のloss診断。初回compile/native失敗は保存し、再試行や設定変更をせず親へ原因を返す。

| 工程 | 事前失敗条件 / E2E入口 |
| --- | --- |
| source/input | 固定input長/SHA、frozen診断source/report、plan/tool pins差、未使用出力でないこと、読取/BWT重複、raw event/frame/plain/inputコピーを拒否 |
| key/history | frozen features::walk(Joint)のcallback keyをcomponent/context/symbol/exponentsへlossless分解し、四family再構成をhand7runsの全eventで確認。rank/length/old history順を変えずfrozen walkへ任せる。hashの固定wrapping式/低12bit、key境界を検査。aliasをexact旧expert再現と呼ばない |
| Fenwick | leaf初期1/observe+2、257domain（length末尾unusedを含む）、sum+2>=32768でobserve前ceilhalf→tree再構築。predictに使った旧状態はrescale前。独立dense oracleで初期、全257への増加、threshold直前/直後、各更新後全prefix0..257、limit1/256/257を比較 |
| mixture | token前のexpert count/prefix/valid total、weight初期1/4、S(k)順序global/symbol/recent/joint、Q32768/k+floor((Q-limit)S)、端点0/Q、正interval、finite/weight sum許容1e-12。手製CDFの全kを独立dense scalar式/actual intervalで比較。invalid token/limit/key/weights NaN/Inf/zero/sum違反を拒否 |
| causal update | p_iは予測時count/limit totalをキャッシュ。posterior=w_i p_i/sum(wp)、next=(255/256)posterior+1/1024。非量子化expert確率でweight更新し、その後各expert leafを一回更新（必要なrescaleは+2前）。未来countを使わないことを手製before/after予測とdense数値で比較 |
| 計数 | rank/length Kahan quantized/unquantized/4expert loss、全event/runs/escape/primary/grammar、prefix query/visit、update/visit、rescale/rebuild、row使用/alias/key distinctをchecked集計。native最後に全24608rowのleaf/tree各位置とdirect sumを一回照合（全更新後oracleとは呼ばない） |
| 境界 | positive leaf/freq、u16/u32 overflow、invalid row/token/limit、lossfinite、weight positivity/sum、RAM estimate/capacity/timeout/output予算、残存processを拒否。f64 floorをportable wireと呼ばない |

aliasの報告はhashed rowの初回keyと異なるevent数、collisionが観測されたrow数、distinct original key数−active row数を区別する。direct global/symbolはexact key rows、recent/jointはcomponent/context込み4096row hash alias。

## capacity含むRAM最悪推定（実装前）

24608rows=32+16384+4096+4096。leaf24608×257×u16=12648512B、Fenwick24608×258×u32=25395456B、合計38043968B。total/first-key各u32×rows=98432Bずつ、used/collision flags各u8×rows=24608Bずつ、visits/alias-events等small counters。hashed original-key bitmapはrecent2^21/8=262144B＋joint2^23/8=1048576B。context weights32×4×f64=1024B。

table/audit配列capacityの計算39577184B＋固定run Vec capacity1048576×12=12582912B＋input2811006B＋frozenhist最大1369112B＋4MiB allocator/meta余裕=60534518B。保守的mix phase上限64MiB=67108864Bを実行前に固定する。初期丸め60000000Bを実capacity足算で補正し親の64MiBへ統一したもので、モデル設定変更ではない。Vecはtry_reserve_exact、runtime capacityから実配列bytesを報告・160MiB以内を確認する。dense oracleはE2Eで1row小配列だけ、final全row照合は追加dense table不要。

BWTは別phase。frozen SA-ISのn/2再帰/drop順を使う50×2811007+1MiB=141598926B（約135.04MiB）推定、160MiB=167772160B未満。BWT完了後だけmix tableを構築し両phaseを同時保持しない。logical/allocator推定で、peak RAM実測・強制quotaではない。

単一設定：rustc edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、compile60s/native120s、source300KiB、全出力8MiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB。nativeは小hand E2E後に固定inputを一度read/BWTし、frozen walk一回で四expert同時更新する。source/tool/input/plan/frozen診断pins前後、finalreport保存後readonly verifier/diskguard/process0。新unit tests、Cargo target/PDB、Git/外部write/削除/製品変更/追加委任なし。

model table保存0B、policy metadataは未定。screen=ceil(quantized loss/8)+escape742+framing285+model-bitlength4+reserve2048で483599B以下でもwire/実coder全復元への必要条件だけ。四nativeのfloating floor同一性未検証、新context独立監査未実施。自己確認と親確認を独立監査と呼ばない。
