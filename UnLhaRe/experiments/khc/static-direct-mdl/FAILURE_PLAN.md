# 静的direct MDL：実装前の失敗一覧

本候補だけを一回screenする。モデル学習・header・予算の診断で、圧縮coder/復元方式/速度実装ではない。fixed483599Bを超えたら不採用と保存し、sweepしない。

| 工程 | 先に拒否・検出する失敗 | 確認経路 |
| --- | --- | --- |
| frontend | sentinel漏れ、非maximal run、next-use順/terminal rank0/active数ずれ、history更新をtoken前に行う、length-1 clamp255やremaining limit誤り、escape varint個数ずれ | 独立scanner対reference observerの全342278 histogram cells/全meta直接比較、grammar digest/Proof14/全frame/plain比較 |
| observer | 数値式/閾値/拒否順改変、hook位置がtoken途中、全branch traceの保持、run_doneが旧previous exponentを新length bucketに誤用 | 最小source変換ledger、token完了/run_done/escape数だけ観測、actual lengthで新bucket更新 |
| quantize | 空global、used count0、単一symbolのfreq32768を15bit保存、未使用tokenへ正freq、量子化freq0、sum不一致、counts/積算overflow、Hamilton tie逆順 | model header E2E fixturesと全freq/cumulative直接比較、checked integer計算 |
| MDL | group/split CDF費用を無料扱い、空groupをown、split childのinheritが誤ったparentを指す、tieでsplit/own優先、unconditionalとtruncated loss混同 | header実bit数対選択費用一致、選択dispatch直接比較、quantized unconditional選択後のvalid-limit別再走査 |
| header | used0/範囲超、重複/未整列ID、range外ID、freq0、sum>=32768、bit切詰め、bytes不足、余剰data、非zero padding、冗長split tag | 事前名付けmalformed fixtureをserialize→mutate→parse拒否するstandalone E2E |
| scoring | 学習済tokenのselected freq0、limit外token、truncated total0、finite loss違反、fraction/ceil/項目sumの誤り | 同run sourceの再走査、全freq/total範囲検査、項別予算を保存 |
| 資源 | input/tool/source pin差、compile60s/native120s超、EXE1MiB/report256KiB/stdout64KiB/stderr16KiB/source300KiB/生成8MiB超 | beforeafter/live SHA/bytes/time、bounded child、最終report保存後disk-budget、owned process0 |

length bucketは初期と長さ1→0、2→1、3-4→2、5以上→3。rank previous min3はsymbolごと、length previous actual lengthもsymbolごと。run sourceはRAM working dataだけで、token sequence/rawtraceを保存しない。無計器reference、observer encode/decode、scannerのhistogramと全frame/fullplain/typed Proof14/statの一致を正常空/一文字/反復/all256/text/fixedで確認する。

2bitタグには4種すべてが割り当てられるので、第五の不正bit値は存在しない。不正tag E2Eはsplitなのに4child全inheritという非canonical tagを使う。headerだけではtraining時に未使用だったcontextを知れず、空contextのinherit canonical化は学習/serializerが保証する。bitstream parserは冗長split/CDF不正/余剰bitを検査する。

数値bits不一致、予算超過、header制約不成立は失敗証拠として保持。旧rootの上書き/削除、製品/API/version、Git操作、外部書込み、新context委任はしない。親確認と自己確認を独立監査と呼ばない。
