# CTS mid-depth: 固定条件の追加比較結果

## 結論

depth5/6/7は実frame<=483599B、全plain2811006Bの直接比較、encode/decodeの全Proof・stats・CDF bits一致を通過した。depth4は既知の484023Bで424B超過。単発sweepのsize合格中ではdepth5がencode/decodeとも最短だったため、次工程の同一binary ABBA候補をdepth8対depth5とする。製品の既定値や最終採用を変更したわけではない。

本測定は固定順・各1回・warmupなしの診断。正式速度<574.5624ms、CPU<=15%、holdout/categories、4native、製品/API統合は未検証であり、7-Zip総合超えや正式改善率を主張しない。別binary・別工程の時間から改善率を計算しない。

## 単発観測

| depth | frame B | payload B | CTS node B | encode ms | decode ms | size gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 8 | 474734 | 474449 | 12582864 | 6997.8691 | 6970.5610 | pass |
| 7 | 475395 | 475110 | 3145680 | 6371.3625 | 6537.2552 | pass |
| 6 | 476361 | 476076 | 786384 | 6037.8096 | 6062.7479 | pass |
| 5 | 478750 | 478465 | 196560 | 5826.3223 | 5923.1339 | pass |
| 4 | 484023 | 483738 | 49104 | 5279.5516 | 5356.1637 | fail |

node BはCTSの実node Vec領域で、全process peakや入力/BWT/RAM frameを含まない。depth5の領域はdepth8の約1/64。timersはencode/decode呼び出しだけで、JSON整形・直接比較・dropを含まない。frame KHQCID01/header285B、header CRCはdepthを被覆する。

| depth | payload CRC | header CRC | base pool digest | CDF entropy bits |
| --- | ---: | ---: | --- | ---: |
| 8 | 3589341169 | 433030689 | 9128444225deabce | 3788636.714502990 |
| 7 | 3095183663 | 1851190028 | 2c0ca63b19a6c9cf | 3793928.762694114 |
| 6 | 930827760 | 2403625219 | bd83b59a0fbb2f54 | 3801656.537973679 |
| 5 | 3616798779 | 621578488 | 0caac94407124a37 | 3820763.985142052 |
| 4 | 2516407690 | 3696859040 | 5bd5c61ec8da4195 | 3862945.676275690 |

共通runs889227/primary1762795/alphabet257/rank・length889227/escape742、branches[2725772,1099568]、grammar58735a2b7383d755、classes[889227,620240,1216305,889227,64372,145969]、plain CRC433441561を維持した。

## 実行と検証

契約SHA76AD586F37805153938D5ED196B1FBC4F360693DF780D64640005999B3AAEC9E。UTC2026-10-03T08:39:15.1885987Zから08:40:31.4138151Zまで、親Execute1回・compile1回・compare-snapshot/selfcheck/sweep各1回。rustc1.98.1/edition2024/opt2/overflow yes/panic abort/debug0、同一EXE。compile exit0/2219.9325ms（既存unused import warning2群）、compare exit0/2198.9844ms、selfcheck exit0/4107.2175ms、sweep exit0/61491.4351ms。候補CLI stderrはすべて空。sweep child processor60984.375msはCPU15%の測定・証明ではない。

sealed-depth8比較392成功/223拒否/22failed predict、digest4ed027cbcaf271d4が成立。独立depth[4,5,6,7,8]はsuccess30/refusal1070/failed predict90/pure5、constructor拒否2/compact形60が成立。selfcheckはnormal/plain/canonical各70、malformed165、short header20、model named70/assertions80、CAP exact5が成立。数値body・seal/guard/commit・CRC・foreign/rebased契約は前段から変更していない。

sweep[8,7,6,5,4]はencode/decode/plain比較/stats比較各5、input/baseline read attempt・success各1。各候補の全plain2811006Bを直接比較した。depth8は旧frame fields24Bとmetadata/payload474694Bを直接比較して一致。depth4の既知のsize・CRC・base/CDF回帰値も一致したが、保存旧depth4frameとの全byte比較を行ったものではない。frame/plainはRAMのみで、全入力のcanonical再encodeは行っていない。

source99件のbefore/after/live SHA・bytes・UTCmtimeを親も照合し、相違0。compiled graph13sources/12edges/root10/unique12、旧basis48/KT64 60/sealed72/failed84/depth89すべてpassed。旧Executeは再実行していない。EXE before/after/live不変、終了時の専有候補process0。PSparser・Rustfmt stdout6件・nonExecute・minimal source substitutionsもpassed。

## 保存と容量

保存先は `build/khc-quaternary-cts-mid-depth-20261003/`、EXE/reportの2件だけ。

| file | bytes | SHA256 |
| --- | ---: | --- |
| report.json | 360935 | 161FA2175DAFEE83507F321969D79F753363F8E6BDE073987EED861CF481E27A |
| depth-o2-yes.exe | 375296 | BBEC5C2D04F99F7B6AA70071C90059D1E94D35634EBC7CDE5E1DE2C7B8C82B56 |

実使用736231Bで8MiB以内。親終了後の空き82310479872B、root通常directory、input/frame/plainコピー・temp/bak/debug/PDB/Cargo target/trace生成0。前段失敗report124513Bと成功EXE/report702221Bを含む、このdepth調査3出力rootの生成物合計は1562965B（約1.49MiB、source・文書は別）。再現に必要な結果だけ保持し、製品/x86/shared cache/version/Git/外部書込みは扱っていない。

## 次工程

sizeと正しさを維持したdepth8対depth5の同一binary ABBA。旧証拠を上書きせず、新契約・fresh output・bounded診断で順序の影響を減らす。正式CPU観測・正式速度・別カテゴリ/holdout・製品統合の未検証条件は残す。
