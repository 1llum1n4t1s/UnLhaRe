# 現hard-cutの段階計測：実行結果

## 結果と検証範囲

Windows x64、Rust 1.98.1、opt3/thin LTO/codegen1、wire_auditだけ有効。親がcompile1/native2を実行した。コンパイラとselfcheck/profileの全childはexit0/stderr0。元runnerは計測後のPowerShell照合で`Math.Max(1, double)`がInt32 overloadへ変換され、2482488208.226507nsで失敗した。数値codec失敗とは区別する。

失敗したreport・runner・EXEは証拠として変更しない。親の`hard-cut-stage-profile/verify-readonly.ps1`で、凍結runnerからEstimate-Near/Profile-Gateの定義だけを抽出し、当該literalを1.0へ1箇所置換して両方向の同じ照合経路を再実行した。さらに独立した8層帳簿、raw NDJSON3件、source/pin before-after-live163組を再照合してexit0。追加compile/nativeは0。readonly初回は親の配列算術の括弧不足で失敗、括弧修正後の2回目で成功した。元reportのstatusはfailedのまま保存し、成功へ上書きしない。

| 検証 | 実測・結果 |
| --- | --- |
| 合成有限fixture | 15群成功、3080枝・16samples、元Result/Err、overflow・負残差・unwind・sticky fault |
| 実codec追加群 | 3群成功、disabled→enabled→disabled、空prefix1、truncated→同process正常復帰 |
| 実拒否 | LCG4096B、payload5B/CRC修復、truncated range stream、abort1/pendingなし。sample0のため拒否の実sample時計は未検証 |
| 元有限E2E | 正常14・破損34・短depth header4、前通常reportの全文一致 |
| 固定入力 | read1、disabled encode1、enabled encode1/decode1、全478856B frame直接一致 |
| 復元・Proof | 全2811006B plain、同型Proof14 Eq、全stats、前通常Proof Debug一致 |
| frame | header285＋payload478571。483599B上限まで4743B余裕 |
| 各方向の枝 | 3825340、Model独立prefix mirror＝[[121,415562,13461,2296628],[1,71469,7502,1020596]] |
| 各層sample | [0,1623,53,8971,0,279,29,3987]。prefix1の0は未計測であり実時間0ではない |
| 計器容量 | State3120B、2Report＋mirrorを含め9144B、予約65536B以内 |
| 実Winピーク | self WS15740928/private12570624B、fixed WS55476224/private52043776B。双方160MiB以内 |
| 生成物 | EXE506368B＋report173299B＝679667B。frame/plain/input/trace保存0 |

数値bodyはModel4観測wrapper・codec6観測接続を取り除くと凍結通常本文と一致する。20sources/19edges/144199B。disabled参照は同じ実装の計器無効版であり独立実装oracleではない。旧通常EXEを再実行した全frame比較も今回行っていない。

## 時間の解釈

計測付きcodec内部の単回時間はencode3575.467ms/decode3056.7186ms。正式速度ではなく、通常候補2114.141/1998.692msとの改善率へ換算しない。全枝のTLS/帳簿とsample時計が実行を擾乱している。

| 区間 | encode sample生合計 ns | decode sample生合計 ns |
| --- | ---: | ---: |
| CTS predict | 1546800 | 1420800 |
| pool predict | 4239700 | 3783800 |
| pool observe | 1123800 | 1025800 |
| CTS observe | 2938200 | 2621200 |
| branch inclusive | 16106900 | 14551700 |

4子の中ではpool predictのsample生時間が最大。branch残りにはcoder/tree/Model guard/audit、entropy計算、計器費用を含み、純粋なkernel時間ではない。

層別N/n推計はencode CTS1148.1782/pool1373.0712/残り1602.1768ms、decode1034.7702/1231.2688/1459.2454ms。推計branch和は実wholeを超過し、whole残差はそれぞれ−547.9592/−668.5658ms。丸めず保存した。確定CPU割合、厳密な全区間配賦、正式速度の根拠には使わない。6層だけsampleあり、prefix1の122枝を完全計時したとも主張しない。

低頻度のwhole実測はencode BWT125.8639/constructor2.714ms、decode inverse89.3475/constructor3.3628ms。empty clock pair10000回276100ns、平均27.61ns。各時間から校正を引かず、非sample時の帳簿費用も除去していない。

## 再現・証拠

- report SHA256: EBAFECF71276F59F19C4041CF806C9993A8ED4BEB22B6D1421C83F89FE70566C
- EXE SHA256: 5A47F5CB93AFB26040FA24070F0463A973F25EBA1010F9C07A1E0EA190D9EEB0
- 凍結runner SHA256: 323A12CF6991EBAE47BAC58759CF709EDEA5D16E36F3EC9D95364242CE94570A
- 修復readonly verifier SHA256: AEB23306C401E29FE686A1FD2C4F83E777FA0443D2873D75F4841C2A5F99D16B
- native実行台帳: version117.3437ms、compile7573.4739ms、self983.1053ms、profile9529.6625ms。これはfullCLI固定速度benchmarkではない。

保存済み証拠の再検証（新規ビルドやcodec実行なし）：

```powershell
pwsh -NoProfile -File UnLhaRe/experiments/khc/hard-cut-stage-profile/verify-readonly.ps1 -ReportSha256 EBAFECF71276F59F19C4041CF806C9993A8ED4BEB22B6D1421C83F89FE70566C
```

元run-nativeは使用済みの専用出力先を持つ一回限りの実行証拠で、再実行入口にしない。後続runnerは浮動overloadを明示して本不具合を継承しない。

## 次の候補と未達条件

pool predict内のexp_negの動的2冪除算を、同じ2冪逆数との乗算に置換する候補を先に有限bit同値と生成命令で反証する。現時点では未実装・未採用、速度効果未測定。entropy log2表は262152B/Modelと追加allocation・短入力初期化費用が増えるため未採用候補に留める。

ディスク空き確認55801790464B。guardは事前事後確認でありquotaではない。他作業の消費へ原因帰属しない。製品dirty、Git、version、API、x86、外部、削除は変更なし。正式fullCLI速度・quiet/warm9・holdout・完成書庫/API・4native・総合7-Zip超えは未達。GOAL active、停止指示なし。
