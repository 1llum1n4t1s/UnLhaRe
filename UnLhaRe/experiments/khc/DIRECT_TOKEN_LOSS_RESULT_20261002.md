# direct-tokenモデル損失の分解結果

## 判定

単なるCDF高精度化だけでsize gateへ到達する仮説は棄却する。固定入力ではconstant prior64が旧rootTotal/4 priorより予測損失を増やした。影響はrankとlengthで逆であり、一つのprior重みを双方へ強制する設計は見直す。これは固定development inputの結果であって、holdoutの一般化や新設計の成功証拠ではない。

## 独立照合・集計

fixed inputを一度read/BWTし、rank/length各889227interval、runs889227、primary1762795、alphabet257、escape742を凍結full statsへ照合。actual旧/P256/Dirichlet interval5335362件を独立配列prefixと通常u128式へ比較した。定期・終端全state27418784値で3モデルのcount一致、rescale一致を確認。全更新直後の全count一致を逐次検査したわけではない。fingerprint20faed056993d70d。

| 集計 | rank（byte相当） | length（byte相当） | 合計（byte相当） |
| --- | ---: | ---: | ---: |
| prior64 - old（連続分布） | +17711.734 | -2402.324 | +15309.411 |
| P256 - prior64（有限CDF・正支持） | +622.924 | +18519.186 | +19142.110 |
| Dirichlet - prior64（有限CDF・正支持） | -665.358 | +294.110 | -371.248 |

- old ideal bits4597717.435179456、prior64 4720192.719255757、P2564873329.600934050、Dirichlet4717222.736975631。
- new-old ideal difference14938.162725byte相当、実payload差14946byte。残差約7.84byteはrange整数割り/flushなどを含む。
- new-P256 ideal差-19513.357995byte相当、実payload差-19485byte。残差約28.36byte。
- 各payloadbits - entropy - 共通escape5936bitsはold426.564821/P256262.399066/new489.263024bits。これらを速度、peak memory、実frameの絶対entropy最適性と同一視しない。
- rankのprior64損失増はlocal T128..511で+6091.17byte、T512..2047で+11958.94byteが中心。lengthの高精度化はP256のsupport/rounding損失を大きく減らした。cold例の50%支持は実機構だが、全書庫差の全部を説明するものではなかった。
- 16cellsと全合計をKahan合算して一致、各component件数を照合した。f64は診断のみ、wireには使わない。一様支持とfloor丸めを個別に分離したとは言わない。

read-only独立explorerもquery/update順、D/Tとlimit prefixの区別、共通連続prior64式、bin/escape/実payload比較に具体的欠陥を見つけなかった。これは実行検証の代替ではない。

## 容量と識別

opt2/overflowyesの1EXE+report、248810byte（約243KiB）、8MiB予算内。EXE219136byte、report29674byte。frame/restore/rawtrace/PDB/Cargo/cacheは生成しない。処理時間は正式比較性能ではない。子実行終了、source/compiler/runtime/input/proof識別値19個とEXEを前後・親再照合、差異なし。

report build/khc-direct-token-loss-20261002/report.json SHA B9C917798B1B335DC12F684AEBE32BC45D58C80E856F500859038702B0F56D5B。
EXE9F40B3022C40C76C0458A068BEB48EDDE5DD2F96DE6635EAFD8A37DF157C91DD。
probe3D81DFF514DCCDE4233838ADD073091D84B948BB282058AE2C44D3A63EECA52C。
verifier22DAFE881A194AA85442BE0378EC054DAC662D80C7C12038C82783C0C5CCB881。
contract C2A63707460093CE9DA219E82DB732BC587F28AE6D4DA47D42A17F4A4B0647F0。

## 次の方向

flat multi-symbol modelのpriorだけを調整する路線を止め、rank/lengthの少数分岐木と、global/symbol/recent/jointの構造文脈を組み合わせる候補を調べる。旧balanced predictorには4種類の文脈があり、今回flatモデルにはその情報が欠けている。4分岐で共通prefixを共有し、少ないrange intervalと豊かな文脈を両立できるかをまず損失・件数だけで反証する。次の診断でsize gateへ届く見込みがなければ、追加full frameや正式benchmarkを作らない。7-Zip総合超えgoal（固定size、同境界encode/decode、CPU15%、holdout/カテゴリ、4native、製品/API統合）はactive・未達のまま。Git/version/公開/x86は変更しない。

