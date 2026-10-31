# Compact 4lane posterior商: 実装前失敗計画

新SIMD候補の正式比較はCPU20%でpreflight terminal、codec CLI0件。同候補を再試行しない。静的probe report CA1522EDF48D3166B6234DA89D8DFADE3AD2AD9AC469FB694702C7EE12373DA2、asm EC30EF8916CBF489A1EE0F76E4F1DE8F9BE95D90D5467C62C29274A08E1543ADで、4Ratio/4CTS Result96B、入力Result128B、4plain商32Bを実測した。scalar分岐もcompilerが2本のSSE2 divpdを出しており、AVX2だけがvector化されたと推論しない。825 static instruction linesは全分岐の数で、動的実行回数や性能ではない。

## 新kernel

- 新別sourceに旧helperを明示対応コピーし、旧source/proofを編集しない。Backend/CPU dispatchとold ratio4の完全実装を残す。
- `try_nonzero4(n,d)`は4件のunsigned numeratorとdenominatorを受け、全部が1<=d<2^32かつn<2^32*dなら同時f64除算する。power-of-twoもこの条件なら扱う。対象外ならNone。
- 全laneでfinite/0..Q+1を検査しi64→u64変換。checked q*dから、1回DOWN(q-1,p-d)/UP(q+1,p+d)だけを許す。いずれもchecked。pは各操作でq*dとの恒等式を維持する。最後にp<=nかつn-p<dを要求し、全laneの厳密商だけをSome([u64;4])で返す。精度不足/積・補正overflowはNoneで、誤商を返さない。
- 実codecはNone時だけ元posterior/error lane経路へ戻す予定。変数状態の変更前に計算し、元leaf→root更新とpoisonを保持する必要がある。今回はまずnumeric検証までで、full組込みは未検証とする。

## 起こり得る失敗と検証

1. unsigned/signed32境界、q≈Q、NaN/丸めの問題: 元9293629recordを同一順で独立u128直接商と逐次比較。opt2/opt3、overflow-checks=yes、scalar/AVX2の4条件。certificateはQの商/余りに基づき、fingerprintだけで証明しない。
2. 一つの無効laneが他laneの拒否順に影響: numeric adapterはchecked product/domain/補正でNoneなら元ratio4へ全batchを戻す。d==0優先/overflowと正常lane混在、tail1/2/3、14 BigInteger商×4条件、負u64/引数拒否を維持。fallback対象は旧helperで再照合する。
3. auditだけ新kernelを使わない: numeric adapterは実try_nonzero4を直接呼び、成功商にCOMPACT=64を付ける。旧SHIFT等のflagsとは別の診断分類とし、compact成功数>0とfallback数>0を要求する。flagsはwire/商には使わない。コード内のdebug cfgでkernel本体を別物にしない。
4. source取り違え: frozen helper9A135D48AD9C80B02B5BF916301EBBA0F95ED3EA578B6E0B0563A4E6E38645C7、frozen audit767A234AF874BA615809039ACE8C6BBE6FF6BDE1C2CC1E38E9ADFA2068941856、compilerCA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BCを固定。明示置換の全文対応と新source/EXE/reportの前後SHA。
5. 出力/容量の増大: numeric root build/khc-compact-simd-20261002は8MiB。全件rawを保存せずbounded要約、EXE2件を/DEBUG:NONEで生成。新Cargo target/cache/traceなし。fresh root一回、child120秒、budget事前/事後。旧/現terminal正式比較は再起動しない。
6. 正確さから性能を主張: 新kernelの実E2E、frame/stdout/restore、拒否/poison、四nativeは後続工程。新candidateの固定正式性能ゲートにも合格しなければ速度改善・7-Zip超えとしない。Option全体のsizeはplain payload32Bより大きくなり得るため、新codegenで別途測る。compactNode u32化は別案で、今回混ぜない。
