# Header minor census failure-first

親PLAN SHA256 C05BC0C6819909CFE29224F1347A6CB50ACE9BD5913780DFE1B042E48853B60B。旧root-history-order source/report不変。この文書保存後に新コードを作る。

- Huffman正常5例：empty(raw)、singleton(length1)、256一様(length8)、偏り3symbol、18symbol Fibonacci(length>15→raw)。256表と非zero符号費、Kraft、決定的tie/再実行を独立算術で確認。
- weight拒否3例：1binがMAX_MINOR+1、複数bin合計MAX_MINOR+1、u32合算overflow。拒否後singleton正常復帰。
- parser正常3例：834root全default、手製全k全leaf modeと混合low/high rootorderのtyped小packet、実Selected→完成global packet。小packetのhist256、全root/leaf/split/order/field bit長を独立整数oracleで比較。
- parser拒否12例：短field/zero長/過大長/切詰め/余剰byte/nonzero padding、reservedmode/k3 index3/depth超過/truncated order、k4 compact minor255×3の残余underflow、k3 minor255×2の残余largest違反。親が実装前に契約済み残余2例の明示追加を指示。理由を直接確認し同process正常復帰。default/direct root mode境界は元全有限E2Eを凍結参照で維持。
- 元packet scan1・コピー0・CDFtrace0。u32 hist256とu8 length256、小scalarのみ結果に保持。Huffman木511node/heap256のactual capacity＋Kraft一時配列を16KiB以内へ固定、report前破棄。decoder/tableの異常復元検証済みとは主張しない。
- 新費用はflag1B/field4B/table128B/padding1回込みで別field。元DP/tree/CDF/loss/Meta/node8cols不変、実codec未実装。empty/maxdepth>15はraw、singleton length1、通常はraw/Huffmanの有効な小さい費用を採る。
- 新JSONcapacity32000/row160/end8、保持結果sizeofをscratch65536へ計上、一時phase actualpeakも報告。32/64/160MiBを維持。
- 新4filesのみ、apply_patchと固定rustfmt非書込syntax/逆probe ledger後READY停止。compile/native/Git/外部/削除/追加委任0。

## 可逆probe ledger

基点root-history-order/probe.rsからの変更は以下のみ。これらを逆に戻すと元全文へ戻る。元packet/原grammar/Hist/Fit/quantize/LUT/CDF/order/DP/lossの実装は凍結pathで直接参照。

1. mod model/bundle/e2eを旧rootのpath model/bundle/frozen_e2eへ置換、新mod census/e2e追加。旧run出力はE2Eのまま、新有限runはcensus_E2Eへ別保存。
2. kind/error識別を新header-minorへ変更、node JSONcapacity35000を32000へ縮小（row160/end8同じ）。
3. 完成data直後にcensus::scan(&data)を1回、元structural countsとの直接比較とsizeof(Census)記録を挿入。Forestparse/再Fit/全CDF/replayは元全文のまま。
4. 元scratch式へ保持census sizeof加算。元model_ram式を保持し、別census_peak_model/phase（Dense+同packet+typednodes/tree/orders+保持結果+Huffman temp+元reserve/side）を算術推定、両phase最大で32/64MiB判定。
5. 旧selected/sameTreeQ/token/header/tree固定値を照合するguardと、新estimated_screen_bytes/estimated_necessary_size_condition_passedを挿入。元screen/teacher/frame/state/adoptionのfield値を維持。
6. 元printlnの開始object braceをnew printへ移し、minor_census/census_E2E/peak/estimated fieldsを先行追加。旧E2Eとnode8cols・原JSON全fieldsはそのまま閉じる。

census保持はu32 histogram256/u8 lengths256/小scalar、heapなし。Huffman一時heapはNode16B*511とusize8B*256＋Vec24B*2、Kraft count512B、戻りEstimate sizeof（move中の一時領域）、control reserve256B。actual Vec capacityを用いて16KiB以内を検査し、nodes/heapを明示dropして返却。空でもbounded reserveを報告する。retained sizeofを含むscratchは65536以内、JSON32000はappend前に検査する。費用とRAM値は算術推定、物理peak実測は元OS計測fieldだけ。

新finite censusは先行5 Huffman正常/3weight拒否/3packet正常/12packet拒否。typed899bit/3minor histogramのtie長[2,2,1]、singleton paid1097B、一様raw2807B、元default109Bからflag込み候補110Bを独立確認。拒否は理由完全一致、元codec/table復元器はまだ実装せず検証済みと報告しない。
