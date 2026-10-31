# mixed Q21 private codec: standalone E2Eと条件付きABBA結果

## 結果と採否

**正しさ・size gateは合格、両方向の平均短縮gateは不合格、未採用。** CTS/poolをQ21、Mathを凍結Q48→Q32に分けた私的形式 `KHQCMQ21` を独立checked u128/i128 oracleと比較した。製品のLZH方式・API・versionには入れていない。現基点はdepth5の旧Q32 CTS/旧pool/旧Math/旧updateのまま。QCANCEL/Math-U64/Alphaの未採用変更を混ぜていない。

固定開発入力Canterbury `all.group` 2,811,006B、SHA256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76` に対する診断1周、warmup0、同binaryのold/new/new/old、全depth5である。この入力はholdoutではない。好都合な値を選ぶための再実行は行っていない。

| 観測 | 旧A | 新B | 判定 |
| --- | ---: | ---: | --- |
| frame bytes | 478750 | 478735 | Bは15B小さい。上限483599B以内 |
| payload bytes | 478465 | 478450 | headerは双方285B |
| encode診断平均ms | 5700.52230 | 5709.30445 | **+0.154059%**、短縮せず |
| decode診断平均ms | 5683.32430 | 5327.04230 | **-6.268901%**、短縮 |
| private候補採用条件 | Bsize上限内かつencode/decode両平均<A | false | **未採用** |

新旧のframe/CTS重み/base digest/CDF数値は別policyなので同値を要求しない。Bの小さいsizeとdecode短縮だけを根拠に総合改善と扱わない。単一ABBA周の微小なencode差から統計的な退行や同等性も断定しない。ただし事前の採用条件に達しなかった結果はそのまま保持する。

## 実行記録

親によるExecuteは1回、code compile1回、候補CLIは `compare` / `selfcheck-old` / `selfcheck-new` / `abba INPUT` 各1回の計4回。9件のRustfmt stdout、rustc version、compile、4CLIの全15 child recordがcompleted/exit0。compileには凍結depth CTSの未使用re-export1警告（559B）があり、エラーではない。9formatterと4CLIのstderrは0B。実行前nonExecuteでは出力rootを作成していない。

| index | 実装 | frame B | encode ns | decode ns |
| --- | --- | ---: | ---: | ---: |
| 0 | old | 478750 | 5811151600 | 5774320400 |
| 1 | new | 478735 | 6000392300 | 5325366400 |
| 2 | new | 478735 | 5418216600 | 5328718200 |
| 3 | old | 478750 | 5589893000 | 5592328200 |

全plain比較4件、それぞれ2,811,006byte、全Proof14field比較4件、同実装repeat全frame比較2件・957,485byteが成功。CDFはJSONの小数表示ではなくto_bitsで比較した。参照frameをmove保持して比較後drop、frame clone・disk frame・disk restore・input copyは0。最大live candidate frameは3枚・1,436,220B、最後reference0。これはprocess全体のRAM peakではない。

旧Aの全stats/CRC/base/CDFは凍結depth5値と一致。新Bはpayload CRC3784693035、header CRC3875567906、base digest `214aa30ab8a7e716`、CDF entropy bits表示3820649.140682749。grammar `58735a2b7383d755`、runs889227、primary1762795、alphabet257、rank/length889227、escape742、plain CRC433441561、branches/classesは旧不変値と一致した。B encode/decode/repeatはB自身の全Proof/全statsで一致した。

## standalone E2E

| 検証 | 実結果 |
| --- | --- |
| 独立primitive/kernel/CTS/pool比較 | 50固定loop、8754 cases。candidate mass64bit/oracle128bit。全成功Result/Errを直接比較 |
| CTS通常stream | pure predict1080、全Snapshot2160、stream全state2376、記録対象observe成功1620 |
| CTS拒否 | predict/observe2979、拒否前後cross state5958。各実装自身の全state不変も確認。constructor拒否2は別 |
| 旧codec | depths4/5/6/7/8、normal/plain/canonical70、Proof encode/decode70・repeat70、malformed165、short20、model named70/assertions80、CAP success5 |
| 新codec | depths0/1/2/4/5/8、normal/plain/canonical84、Proof encode/decode84・repeat84、malformed204、short24、model named84/assertions96、CAP success6 |

1620はloopで記録するCTS observe成功件数であり、foreign fixtureの準備に使った追加成功216を含む全API呼出総数ではない。KT reserve1、alpha最低1、q0/factor0、CAP、stale/foreign/rebased/current guard、負数ゼロ方向丸め、Q21→旧Mathのchecked_mul(2048)、feature/mass domain、prefix0/5/maxのsmooth拒否も検証に含む。

新旧selfcheckは正常全plain・canonical全frame・全Proof14を直接比較し、model拒否では全base値/totals、pool weights、CTS全nodes/history/observations、serial、audit entropy/correctionのto_bitsまでbefore/afterを比較した。新formatは旧KHQCID01/KHQCIP01/未知magicを早期拒否する。alloc/write/sync fault injection、一般8MiB入力、cross-native環境は今回検証していない。

## 記録是正と独立確認

実装前に失敗分類と新policyを固定し、コード前の件数誤記・prefix1のErr分類を直した。POOL-scoreの負小数exact goldenは数値body後・comparison fixture前、smooth guard負例は数値body/fixture後に具体化した。全exact fixtureがbody前に保存されたとは扱わない。詳細は `quaternary-cts-mixed-q21/FAILURE_PLAN.md` の保存順補足に残している。

親の実行前確認と別文脈のreadonly explorerにより、数値bodyの正常domain/guardと実行root・runner・固定loop・timer・frame所有を確認した。smoothのprefix入口を両独立bodyに追加。別の独立検証で失敗時の完了件数/recipe不足が見つかり、Execute前に親が失敗JSONを補強した。再確認では対象範囲の実行前阻害なし。固定input identityは旧Alpha149 sourcesの中でSHA/bytes/UTCmtime検査とreadlockを受けることを親・独立担当とも確認した。

失敗時はplanned/completed Result比較・phase・fixture・最初のstate/Proof field/node/child・malformed depth/recipe/expected/actual/header64・short truncate長をbounded JSONに残し、非zero結果も解析保存してから拒否する。凍結model helper内の部分assertion数は観測できないので失敗時に全16件完了と推定せず、aggregate group予定1/完了0と内部件数不明を区別する。今回全CLIは正常成功で、補強した失敗記録・panic/timeoutの経路自体は動的に未検証。

## 固定証拠と容量

| 証拠 | bytes | SHA256 |
| --- | ---: | --- |
| build/khc-quaternary-cts-mixed-q21-20261003/q21-o2-yes.exe | 582144 | `661ACA5CFA904FB72848C20AA087B62D0C942EEF7099A4A5FAB58EA3105DE003` |
| build/khc-quaternary-cts-mixed-q21-20261003/report.json | 258738 | `2866C1AD9CB11F008F3856ED2B36560B569A42734F186D3F0C6A49D469EBD853` |
| QUATERNARY_CTS_MIXED_Q21_CONTRACT_20261003.md | 契約固定 | `E2268BEDAA246D76FE8227DBA664627AA6AAC498A604F04C51FE5C8CF4FA3C54` |
| quaternary-cts-mixed-q21/FAILURE_PLAN.md | 36915 | `B2B6BCD2F56BF46C412D13BE3A7C916438C2B48A3F2FF85552695D28B3130DDF` |

旧149+契約/前結果/実現性3+新11=163 identitiesのSHA/bytes/UTC ticksをbefore/after/liveで確認し、親の追加live照合でも不一致0。EXEもbefore/after同一。compile graphは17 unique source/17 edges、数値codec本文とtimer本文は凍結テンプレと一致。runtime PowerShell7.6.5・rustc1.98.1の契約SHAを照合し、edition2024/frame_audit/primitive_audit/opt2/overflow-checks=yes/panic=abort/debuginfo0/link DEBUG:NONEで実行した。

新11source合計198,895B。今回の最終buildはEXE/report2件のみ840,882B（約0.802MiB）、8MiB予算内・EXE1MiB/report512KiB以内。report.disk_after.used_bytes=745865は最後のreport保存**前**の値であり、最終使用量840882と混同しない。親のlive最終列挙で追加ファイル/所有codec processは0。今回削除はしていない。再現に必要な最小ソース・EXE・bounded reportを固定証拠として保持し、共有cache・既存input・x86版へ触れていない。

同日のQCANCEL/Math-U64/Alpha-codegen/Alpha/Q21の5限定build root合計は10ファイル3,426,405B（約3.268MiB、source/doc除外）。今回実行直前のfree89,130,184,704B、runner最終保存前89,085,202,432B、親の別live確認88,313,303,040B。ドライブ全体の変動をこの約0.8MiBだけの処理へ帰属させない。最低5GiB+8MiB境界は満たした。

## 未達と次の限定工程

正式single-thread codec median<574.5624ms、machine CPU<=15%、独立holdout/categories、4 native環境、製品/API統合は未達/未検証。診断encodeは約5.7秒で、この結果から7-Zip超え・完成・採用は宣言しない。goalはactiveのまま。

確率部の低精度化だけではencode短縮が確認できなかった。次は旧Q32基点のencode/decodeをstageごとの集約時間で観測し、BWT・payload/model・CRC/headerの時間寄与を分ける限定計測案を固定する。これは次の仮説選択用で、計測入りbinaryの総時間を採用gateの時間や正式benchmarkへ流用しない。新しい測定は別の失敗計画・source/出力予算を先に固定し、既存入力だけで小さいEXE/JSONを生成し、raw trace・frame/restoresのdiskコピーは作らない。
