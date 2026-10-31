# CTS depth: 結果と次の比較基点

## 結果・採否

明示再開後、深さ0/1/2/4/8の研究用候補を実装し、5件すべての完全復元・数値監査・安全性検証に成功した。固定frame上限483599Bを満たしたのは深さ8のみ。浅い候補は速さとノード領域の削減を観測できたが、サイズ条件を満たさず採用しない。深さ4は424B超過で、条件を緩めず深さ5/6/7を次の候補とする。

| depth（測定順） | 実frame B | payload B | CTSノード領域 B | encode call ms | decode call ms | size gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 8 | 474734 | 474449 | 12582864 | 7463.3164 | 7309.4000 | passed |
| 4 | 484023 | 483738 | 49104 | 5372.6436 | 5320.2040 | failed: +424B |
| 2 | 514242 | 513957 | 3024 | 4465.7858 | 4408.1640 | failed |
| 1 | 517022 | 516737 | 720 | 3937.9904 | 3938.0955 | failed |
| 0 | 517842 | 517557 | 144 | 3331.5239 | 3166.6724 | failed |

単発・固定順・同binaryの診断sweepで、warmup/repeat/内側timerは0。計時はencode/decode call前からreturn直後、stats/JSON/比較/dropを除外する。改善率・正式中央値・CPU15%以下は主張しない。CTSノード領域は実際のVec長とNode sizeofで検証したが、全体peak RAMではない。前段sealed平均や別binaryの値から改善率を作らない。

7-Zip総合超過は未達。正式速度<574.5624ms/機械CPU<=15%、holdout/categories、4native、製品/API統合は未検証。製品default/API/wire/version、Git stage/commit/push、外部公開は変更していない。

## 変更と失敗の是正

元CTSは9段・classあたり87381node固定。新候補はdepth0..8をallocation前に検査し、classごとのsum(4^level)に合わせたcompact領域を確保する。predict/gather/prepare/commitはactive段のみ、固定9配列のinactive部分はcanonical zero。sealed通常経路と合法modified fallback、current guard順、拒否時全state無変更を維持した。

私的wireはKHQCID01、固定ヘッダー40Bにdepthを格納し、headerCRCもdepthを被覆する。decoderはframe内depthだけでModel/CTSを生成する。旧形式や製品形式の移行ではない。

追加静的監査で見つかったT2（失敗時call/read件数の過大・過小報告）は、実行前のcall counter、成功後の比較counter、read attemptとread successの分離へ修正した。正常sweepで実績5/5/5/5、read各attempt/success1を観測した。失敗注入CLIは追加実行しておらず、部分失敗時counterの全パターンは静的確認に留まる。

元段階のExecuteはcompile E0432で失敗した。凍結integer_poolが参照するcrate::integer_ctsのroot aliasが欠けていた。候補CLI0、EXEなし。元8sourceと失敗reportを凍結保持し、新しいrepair段階は3module pathと `use reference_cts as integer_cts;` の追加だけで是正した。新rootのbodyは元sourceへの4か所の置換と直接比較して同一を検査し、修正版compileと実際の全E2Eに成功した。元rootへの上書き・再Executeはしていない。

## 直接比較とE2E

- depth8と旧sealed: 成功392、拒否223、failed predict22。全RawSnapshot/成功後全nodes/history/observationsを直接比較し、拒否・failed predictでは旧新の全state無変更も確認。digest4ed027cbcaf271d4は補助でありhashだけの証明ではない。
- depth別: 成功30、拒否993、failed predict60、pure predict5、constructor拒否2。compact全6class×history0/65535×5depthの60件で全node区画、active ID、inactive zero、固定容量を直接照合。未改変foreign-depthは拒否、現行visibleへ完全交換した合法rebased tokenは従来fallbackで受理した。
- selfcheck: normal/plain/canonical各70、malformed165 exact reason、short36/37/38/39Bの拒否20、model named70/assertions80、CAP exact5。supported depthのCRC未修復改変もheader CRC mismatchで拒否した。
- full sweep: 全depthの元入力2811006Bと復元を全byte直接比較5回。encode/decodeの全Proofとstatsを比較5回（CDFはf64 bitsも比較）。入力と旧frameのRAM読込各1回。
- depth8 bridge: 旧新[8..32]24B、旧[36..]/新[40..]474694Bのmetadata/payloadを全byte直接比較。新frame474734B、header285B、payload474449B。旧との差はmagic/depth4B/headerCRCだけ。

共通runs889227、primary1762795、alphabet257、rank/length各889227、escape742、branches[2725772,1099568]、grammar58735a2b7383d755、classes[889227,620240,1216305,889227,64372,145969]。depth8 plain/payload/headerCRC433441561/3589341169/433030689、base-pool9128444225deabce、CDF3788636.714502990。他depthの数値はreportに保持し、固定旧値へ強制していない。

## 実行台帳・証拠・容量

元Execute: UTC2026-10-03T08:11:53.2563807Z～08:12:00.5893707Z、compile1/exit1/E0432、CLI0。修正Execute: UTC08:21:49.1804758Z～08:22:52.3751956Z、compile1/exit0、comparison/selfcheck/sweep各1/exit0。合計compileは2回（失敗1+別修正段階1）、成功を1回だけと偽って合計を隠さない。無制限再試行なし。

修正版compile2371.9047ms、比較2274.8375ms、selfcheck4099.2928ms、sweep48840.3115ms（いずれもchild launch/drain込みの診断wall）。compileはunused import warning2群、候補CLI stderrは空。sweep TotalProcessorTime48468.75msは機械CPU15%の証明ではない。

Windows11 Pro10.0.26300/x64、Ryzen5 7640HS6core/12logical、PowerShell7.6.5、rustc1.98.1。compiler/runtime SHAは元契約どおりで前後固定。compile flagsはedition2024/frame_audit/primitive_audit/opt2/overflowyes/panicabort/debug0/DEBUG:NONE。source cwdはC:/Users/IMT/dev/UnLhaRe/UnLhaRe、親preflight cwdはその親。

| artifact | bytes | SHA256 |
| --- | ---: | --- |
| build/khc-quaternary-cts-depth-20261003/report.json（失敗証拠） | 124513 | 9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0 |
| build/khc-quaternary-cts-depth-repair-20261003/depth-o2-yes.exe | 375296 | E719F8B7237A200EEAE67CCBBAFC7B50EA5F489AA9F6AFAB31909772BA545A98 |
| build/khc-quaternary-cts-depth-repair-20261003/report.json | 326925 | 96FF61D2B125982BCA413CC63EA86FA2DDCAC61AD7B157C744974E29FFC63DE2 |

新repair出力は2件702221B、元失敗証拠込み826734B（約0.79MiB）。各8MiB上限、生成前scalar予約1572864Bと終了guard通過。親最終空き83262423040B（約77.54GiB）、他作業の空き変動を本段階の消費とは扱わない。frame/plain/input disk copy0、temp0、owned codec process0、Cargo cache新設0。旧証拠、共有cache、x86は保持。用途を終えた今回の一時物はなく、残した3生成物は再現・失敗説明に必要な証拠である。

元source84前後/live、修正source89前後/親live、旧48/60/72basis、failed84closure、EXE前後のSHA/bytes/UTCmtimeは全一致。graph13sources/12edges/root10/unique12、root aliasのstatic guardも成功。nonExecuteは出力rootを作らず、旧Executeの再実行なし。reportのraw/parsedはvalidator前に保存した。容量guardはOS write quotaではない。

修正契約SHA029D352BE256560D3DF641F7FC31D18390CD0E2A71F20C7FB877498A22025350。repair sourceはprobe7571B/SHA59568EB04D772E65F20A52AB86184BF9E6DD2003744173223305EF61C4962E7D、runner51284B/SHABE06BD702468CC104E36B9840E0783AC20F1439278B6C1329A040FAFCF31F7F0、plan3466B/SHA743845A1D0E5DDB8C343FAC49C49FC9293AEDBD01A2539C9C2E364F9055BAA96。元8sourceの識別値は元reportとrepair closureに保持する。

## opop台帳・次の工程

Modernizerは凍結runtime/依存維持。Normalizerは自己記述private depthを研究用に実装。Performanceは候補比較完了、浅depthはsize条件で不採用。Cleanerは重複大型データを生成せず証拠のみ保持。Hardeningはdepth bounds/CRC/拒否順/atomic commitを実確認。Testerは事前失敗計画とstandalone E2Eを採用。Asyncはpure予測・RAM drop・child finally解放を維持。Startupはノード領域削減を実確認、全体peakは証拠不足。Intelは外部現在値不要で非該当。

親はcore/全差分/runner・修正版差分をレビュー。読み取り専用analystはguard/depth伝播/固定件数を確認しT2を指摘（compile・実行の独立検証ではない）。worker-high要求gpt-6.1-sol/high、analyst要求gpt-6.1-sol/medium、役割既定を利用しhidden実効設定の独立測定はしていない。最終git diff --checkはexit0、既存DESIGN.mdのLF/CRLF warningのみ。製品全build/4nativeは未実施。

本段階はprogress。次はsize条件を維持した深さ5/6/7の比較を事前契約で固定し、その後に合格候補だけ同条件ABBAへ進める。深さ4の上限を緩めたり、単発時間を正式速度達成へ読み替えたりしない。
