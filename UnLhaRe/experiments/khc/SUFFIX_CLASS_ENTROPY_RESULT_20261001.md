# 圧縮率低下はrank mantissaに集中していた

旧CTSと新suffixを変えず、実際にrangeへ渡した更新前Q15予測を整数histogramへ記録した。新suffixのmixed loss増加の近似推定は合計5139.8704B、その99.1933%に当たる5098.4052Bがclass3（next-use rank-1のmantissa）だった。class0の約41.4660Bを除く残り5classesの差はほぼ0。実書庫の増加5123Bとは約16.8704B異なるため、書庫byte数の厳密な内訳としては扱わない。

## 実行した検証

`build/khc-suffix-class-entropy-20261001/report.json` SHA `CB1FD14D1FD8E5BE169D2ECFBF7D4F7D419C2D3EA65FE3F122727D4A913B3BC4`、status `verified_class_histograms_not_timed`。17checks/13CLI/40identities、実行中変化/timeout/tmp/reparse0。終了後も全40identityの現存長さ/hash一致を再確認した。verifier SHA `2A2E9D522AA0E9456B04CBD0931E41818E0513941311E0EB62283A3D8707CEF6`。Rust1.98.1/edition2024/panicabort/opt3/Windows x64。

old/new sourceは各元wrapperへ、モデル参照の対応とcfg gated diagnostic module/初期化/観測hook/成功公開後dumpの5変換以外の全文対応を確認した。histogramはbit受理後・全model更新前の独立した整数件数で、modelへ値を戻さない。raw magic `KQHIST01`、7classes/3components/32768bins、5505044B。各class全3componentのbit総数、bin0不使用を確認。

両variantの固定group各2encode＋1decodeで、frameとhistogram反復が全byte一致、復元groupとencode/decode histogramが全byte一致。旧frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`、新frame488592B SHA `F9B76F4DED7C402BC3B06BBDC499A5A7B41CE758067F8EFA24F3ED1CCB9B4531`という元のframeとも全byte一致した。旧新のprimary histogramは全7class/全binで一致。各variantの既存frame/auxを操作前に拒否してsentinel保持、相方出力未公開を確認した。

## class別の観測

下表のgainはprimary loss minus expert loss。正ならそのexpertがprimaryより良い。lossは整数histogramから計算したf64近似であり、実時間や厳密frame長ではない。

| class / grammar | bit数 | 旧CTS gain(bits) | 新suffix gain(bits) | mixed増加推定(B) |
| --- | ---: | ---: | ---: | ---: |
| 0 / rank終端(rank==0) | 889227 | 2694.402 | 2362.674 | 41.4660 |
| 1 / rank==1 | 888970 | -30797.791 | -43191.717 | -0.0003 |
| 2 / rank-1 unary exponent | 2472373 | -107063.508 | -115929.132 | -0.0005 |
| 3 / rank-1 mantissa | 1835474 | 167687.244 | 126900.009 | 5098.4052 |
| 4 / run length==1 | 889227 | -50893.509 | -69699.295 | 0.0001 |
| 5 / length-1 unary exponent | 426165 | -23656.080 | -31387.462 | 0.0001 |
| 6 / length-1 mantissa | 221182 | -8365.192 | -12626.008 | -0.0001 |

実grammar合計7622618bits。sourceの`Stream::rank/length/integer`からclass意味を確認し、先行件数診断の各class総数とも一致した。これらは固定development上の観測であり、他書庫でも同じclassが常に勝つという結論ではない。

## 次の設計へ使う範囲

全classでCTSを一律に軽量化すると、強いclass3の予測能力を失うことが今回の入力で観測された。反対に5classesではprimaryが両expertより良く、CTSは計算していても最終mixtureにほぼ役立っていない。重いexpertの計算を過去の予測gainで選ぶ、causalな段階制御を次の仮説とする。

観測したclass0/3だけを固定で残すことや、corpusを見てrouteを事後選択する方式は採用しない。新仮説は現在bitを見る前の軽いexpertの累積lossから重いexpertの必要性を判定し、停止中の履歴を保持して再開時に順にreplayする方式である。再開時のモデル状態の整合性、journal memory上限、replay費用、初期学習中の書庫増加は未解決。軽いexpertが重いexpertの必要性を判断する代理指標として十分かも未証明。詳細は[次の支持範囲](CAUSAL_EXPERT_SCHEDULING_FEASIBILITY_20261001.md)に分離する。

## 保持と未達

今回の所有rootは43815730B。原本整数histogram、反復/decode照合用raw、EXE、frame/restore、source/provenance/reportを再現証拠として保持。用途終了の一時物/reparseは0、関連processなし。共有cacheや他作業を削除しない。補助担当はmodel capacityで起動失敗し、親が直接調査した。新独立作者監査としては扱わない。

性能を測定しておらず、CTS計算件数やlossを速度削減率へ変換しない。固定size gateの新suffix不採用は変えない。holdout/カテゴリ、同境界decode/peak memory、4native、製品統合、総合7-Zip超えは未達、全体goalはactive。
