# next-use rank/run-lengthのdirect token試作: 実装前契約

前段の同一component件数診断は7確認に成功しPROGRESS。4lane全省略は10.849%で、枝の追加は見送った。今回は889227 runに対する7622618 binary eventを、rankとlengthのmulti-symbol tokenへまとめる新研究形式を設計する。既存format/product/API/level0/4/5/6/7は変更しない。速度・サイズ改善は仮説であり、完全frameと固定評価で確かめるまで採用しない。

## 算術・モデル仕様と失敗条件

1. multi_rangeはbyte正規化range coder。initial low0/range u32::MAX、normalize range<2^24、carry遅延ShiftLow、flush5。intervalはtotal in 1..=81920、frequency>0、cumulative+frequency<=totalを処理前に検査。unit=floor(range/total)、low+=unit*cumulative、range=unit*frequency。unused rounding gapはsymbolへ割り当てず、decoder slot=code/unitがtotal以上なら拒否する。消費前にslotが選んだinterval内にあることを確認する。prefix0/min5bytes/truncation/trailing/noncanonical terminalを拒否し、finishは全byte消費とcode0を確認。u128/BigIntegerの独立interval算術とstream roundtripで反証する。
2. CDFはFenwick累積counts。alphabet1..257、key1..4096。globalは各symbol count1、localはcount0。重みK=4、combined frequency=global+4*local、cumulativeも同じ線形結合。rankはcurrent active数、lengthはmin(remaining,256)にCDFをtruncateし、禁止tokenへ質量を割り当てない。global/localのtotalが16384へ達した更新後、各count=(count+1)/2でrescaleしtreeを再構築する。globalは常にpositiveで、combined total<=81920。slot→token検索は同じ加重Fenwick nodeを使う。integerのみでwireを決める。
3. CDF反証は別のnaive count配列・逐次和・linear searchで、prefix/interval/selection/更新/rescale後の全countsを照合。alphabet16/256/257、複数keyとvariable truncation、zero local、skew/alternating/seeded状態を通し、normal/overflow checksとopt2/3の4条件で一致を要求する。bad alphabet/key/token/limit/slotを処理前に拒否し、その後の状態を保つ。巨大recordを保存せず件数/fingerprint/要約だけ保存。
4. allocation/cap: modelはkey<=4096でbounded Vecへtry_reserve_exact。private counts/Fenwickを外から変更しない。root total/local totalとstored countはchecked演算でinvariantを検査。rangeはhard byte limit、bounded reserve/growth、allocation失敗はResult。primitiveの検証が成功しても新token grammarやfull codecが検証済みとは扱わない。

## full prototypeへ接続する仕様（primitive成功後）

5. 元のBWT/next-use active list/packed alphabetを再利用する。これは普通のMTFではない。rank local key=symbol*4+min(previous rank,3)、rank alphabet257。length local key=symbol*9+floor(log2(rank+1))、length alphabet256。previous rankはそのsymbolの前回runが完了した後だけ更新する。未来のrank/runをcontext作成に使わず、decoderも同じ順序を実装する。length1..255はtoken0..254、256以上はescape255+uniform256 intervalのcanonical LEB128(length-256)。remainingを超えた長さ、無効rank/escape/非canonical varint、active未消費、adjacent同symbolを拒否する。
6. 新magic KHNTOK01の別研究frame。plain/payload CRC、primary、alphabet metadata、declared lengths、canonical packed alphabet、complete container、bounded allocation/no-clobber/CRC後公開を維持する。旧magicは新decoderで拒否し、旧decoderへ新frameを渡した拒否も確認する。既存codec/source/proofは編集しない。Runはu16 symbol/u32 length/u32 nextで表し、最大input8MiB+sentinelがu32へ収まることを検査する。payload上限はactual transformed lengthから8*n+32とし、generic total/frequency境界から各rank/length intervalのnormalizeは最大3byte、uniform escapeは最大1byteとなることにbindする。
7. 比較: 最初に7入力のencode/decode/正常・異常・決定性でfull artifactを作り、総サイズを固定483599Bへ照合。正式single-thread全CLI encode median574.5624ms未満、CPU15%、warmup1+9等は維持。これまでのterminal候補/確認待ちobserver初期化分離を再実行しない。new comparerでは旧KTと新batchのreciprocal_proofs key衝突を別名へ分ける。format違いをold frame SHA不変の証拠へ読み替えない。

## 所有・容量・作業境界

- 親: direct-token/cdf_model.rs、model_audit.rs、verify-model.ps1、後続codec/統合検証と本契約。worker: multi_range.rs、range_audit.rs、verify-range.ps1、RANGE_FAILURE_PLAN.md。互いのファイルを編集しない。
- primitive生成先はfresh build/khc-direct-token-range-20261002 と build/khc-direct-token-model-20261002、それぞれ8MiB。2個の小audit EXEとbounded JSONだけ、見込み各1MiB以下。disk-budget前後、/DEBUG:NONE、Cargo/cache/PDB/raw traceなし。compiler1.98.1/SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、各child120秒/出力65536文字以下、runtime/CWD/argv/実source/hashを保存。
- 将来のfull rootは別途事前予算化。input/shared cache/過去proof/他版は消さず、用途を終えた今回の一時物だけexact owned path・non-reparse・writer停止を確認してRemove-Item -LiteralPath。失敗時は再現最小限を残し自動再試行しない。apply_patchでsource編集、Git stage/commit/push・version・公開・外部書込みを行わない。
- independent holdout/カテゴリ・同境界decode性能・四native・製品/API安全性を含む7-Zip総合超えは未達。primitive/小corpusの成功へobjectiveを縮めずgoal activeを維持する。
