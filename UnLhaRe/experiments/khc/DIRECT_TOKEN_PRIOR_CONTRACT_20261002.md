# direct token正規化事前分布: 次の反証契約

前候補 `KHNTOK01` は完全E2Eに成功、固定frame575791byteで483599byte gateに失敗し不採用。今後も同gate、正式CPU/速度/回数/境界を変えず、失敗した候補の測定を繰り返さない。この契約は新しいCDF仮説のprimitive実装前に記録する。まだ実装・検証・性能改善の証拠ではない。

## 仮説と新しい整数CDF

旧freq=root+4localのglobal正規化分布への事前強度はrootTotal/4。仮説: この強度を固定すると、局所文脈の情報を利用でき、サイズgapを縮める可能性がある。実測で完全frameが改善しなければ反証される。global/localのroot1/local0、alphabet1..257、keys1..4096、16384 rescale、rank/length文脈・grammarは据え置く。

新CDFはP=256で固定。index kまでのroot/local prefixをR(k),L(k)、rootTotalをDとする。

`C(k) = k + 4*L(k) + floor(256*R(k)/D)`

token frequency=`C(k+1)-C(k)`、legal truncated total=`C(limit)`。+kにより各tokenは必ず正、全count local<16384からtotal<=257+4*16383+256=66045<=81920。旧range primitiveの検証domainを広げない。Fenwick selectは候補indexとroot/local prefixを同時に追跡し、node単体を独立に丸めず、累積全体を正規化してslotとの比較を行う。context/causality/update順は同じ。full接続時は別magic `KHNPR001` として旧frame/newdecoder、新frame/旧decoderを相互拒否する。

## exact scalingと想定する失敗

- scaleを簡略化する場合もinteger exact floorを証明する。D in1..16383、prefix R in0..D、n=256R、m=floor(2^32/D)。guess=floor(n*m/2^32)、remainder=n−guess*Dを計算し、remainder>=Dならguessを1増やす。0<=n/D−n*m/2^32<n/2^32<1なのでguessは正解か1小さいだけ。productはu64で、prefix<=Dからn*m<=256*2^32。この証明だけで実装を検証済みとは扱わない。
- D0/>16383/prefix>D、alphabet/key/token/limit/slotを拒否し状態を保つ。rescale後にscaleを更新し忘れる、CDFのtoken頻度とprefixで異なる丸めをする、Fenwick massを個別丸めして検索がずれる、全CDF/截断/ゼロlocalや希少symbolで頻度0になることを失敗条件に含める。
- naive oracleはroot/local生配列の直接累積と通常整数除算、linear select。候補のreciprocal/Fenwickをoracleへ流用しない。新scale helperは通常/u128除算と境界/seededで別照合する。modelは前 primitiveと同じalphabet16/256/257、13key、各131072更新、root/local rescale、全counts、拒否後継続を4compiler条件で確認する。

## 次の実装・容量境界

sourceは新 `experiments/khc/direct-token-prior/` に分離する。旧direct-token source/codec/proof/reportは編集しない。parentはCDFとscale helper、後続fullcodecを所有。独立した有用なverifierは別workerへ委任する場合に所有を明示する。

新primitiveはfresh `build/khc-direct-token-prior-model-20261002`、8MiB/4小EXE+bounded JSON、予想1MiB以下。disk-budget前後、bounded reserve、child120秒/出力65536文字、/DEBUG:NONE、PDB/Cargo/cache/rawtraceなし。必要なproof/hash/最小再現を残す。full生成・正式評価はprimitive成功後に別の実行前容量契約を記録する。失敗root上書き/同条件無制限再試行なし。Git/version/公開/外部書込み/x86なし。

完全な7-Zip総合超え（サイズ、encode/decode、holdout/カテゴリ、4native、製品/API安全性・統合）は未達。新CDFの成功をfull objective達成へ読み替えずgoal activeを維持する。
