# hard-cut 段階計器：先行失敗契約

親PLAN SHA8293A7E7B78F56A090702A5EA20DDB6227065138890BDC6AE65BA5B70C407913を全文確認。phase1は本書、profile.rs、profile_e2e.rsだけ。compile/native/verifierは0、親のphase2接続・単回実行前に全編集停止する。元83件を件数へ足さない。

## APIと帳簿

reset(enabled, Direction::{Encode,Decode})はpending branch/wholeが無い時だけ合法。正常resetは方向別帳簿を初期化するが、既存sticky faultは消さない。有限E2E専用audit_clearは各独立fixtureの前だけ診断状態を消す。branch(component,prefix)はcodec所有RAII、commitは4stage全成功後1回だけ。未commit Dropはabortとして解除する（数値Errの正常帰路であり、それ自体は計器faultではない）。pending状態でsnapshotのvalidateは未終了を拒否する。DropはTLS/RefCell借用失敗でもpanicしない。

stage(id, closure)のid=0 CTS predict、1 pool predict、2 pool observe、3 CTS observe。closureは計器入力が不正でも必ず1回実行し、そのResultを加工せず返す。borrowをclosureへ持ち越さない。stage Err/panicはerror/branch abortとして数え、診断faultで元Errを上書きしない。whole(id,closure)は0 BWT、1 inverse、2 constructor。wholeをbranchと重ねない。

component0/1×prefix1..4、各層1-based ordinal128/384/...だけ時計を読む。全枝・sample・commit/abortと各子attempt/success/errorを分離。sampled parent、4子のtimer pairs/nsを分離し、abortも閉じた時計を記録する。親子負残差はfault、0 clamp無し。全call TLS/counter擾乱を明記し、sampleだけの時計校正では除去できない。

## 保存前に固定した有限census

profile_e2e::runは以下の独立15 fixturesを順に実行しJSON1件を返す。未実行の期待値である。

| 群 | 件数 | 固定内容 |
| --- | ---: | --- |
| core8 | 1 | 8層各385枝、各4stage成功、合成parent10ns/子各1ns。枝3080、samples16、commit3080/abort0、各子attempt/success3080/error0、各子pairs16、parentpairs16、parent160ns/子各16ns/残96ns。ordinal128/384を直接確認。 |
| disabled/reset/whole | 1 | disabled hooksはoperation実行のみ、Encode→Decode reset、whole3成功各1、時計合成各5ns。 |
| branch failure | 1 | 4stageそれぞれで元Err markerを返す4枝＋stage後coder Err相当1枝＋stage後guard Err相当1枝、abort6・pendingなし。同process次の正常枝1commit。 |
| invalid component/prefix | 1 | component2、prefix0/5の3拒否、各scope inert・operation値保持。 |
| nested/reset/direction/unfinished | 1 | nested branch、active reset(false,Encode)、active reset(true,Decode)、active validateの4拒否。outer Drop解除。 |
| stage contract | 1 | no branch、id4、順序1先行、重複0、error後stageの5拒否。 |
| repeated commit | 1 | 成功後commit2回目を拒否、pendingなし。 |
| early commit | 1 | stage0だけでcommitを拒否しabort、pendingなし。 |
| whole contract | 1 | invalid whole3、nested whole、branch中wholeの3拒否。 |
| counter overflow | 1 | audit seedで枝数u64MAX、次begin拒否。公開数値入力で到達可能とは言わない。 |
| timer sum overflow | 1 | audit seedでsample子ns u128MAX、+1拒否。 |
| negative residual | 1 | audit合成parent3ns/4子各1nsで負残差拒否。 |
| reversed clock | 1 | audit合成clock end<startを拒否、pending解除。 |
| unwind cleanup | 1 | catch_unwind内stage closure panicを1回、error1/abort1/pendingなし。実numeric panicをDropの追加panicで置換しない。 |
| sticky/reset | 1 | 最初のfaultの後別fault・正常resetでfirst fault不変、fault count増加を確認。 |

合成oracleは診断seed/合成時計を使い決定的に帳簿を比較する。runtime実elapsed、公開入力到達性、実codecの同値性を検証したとは呼ばない。catch_unwind fixtureはpanic=unwind設定を必要とする。synthetic時計はaudit専用thread local modeで、通常modeの実時計と別表示。

## phase2へ残す検証（phase1で実行済みとしない）

凍結14正常/34破損/4短header、disabled→enabled→disabled全frame、空input prefix1、encode/decode reset、拒否→同process正常。LCG0x6d2b79f5/4096Bのpayload先頭5Bへ短縮しlength/両CRC修復、enabled decodeのtruncated range stream、abort>=1/pendingnone（sample0なら実sample時計未検証）。固定2811006B read1、disabled encode1 frame→enabled encode1/decode1、全478856B/fullplain/Proof14/stats直接比較。元数値Result・浮動順・guard・commit不変の全文allowlistとsourcegraph/tool/input/PLAN pins。

identity/ledger/全frame/plain/Proof差、timeout/compile/panic/保存/資源超過はrunnerで失敗保存。N/n推定は診断のみ、whole超過なら負残余をそのまま報告。空clockpair10000回をcodec外一度、減算無し。raw trace/perbranch allocation無し。

## 資源と判定境界

計器は固定8層×4子と3whole、固定長faultのみ、State実sizeof<=65536を検査。ソース＋PLAN300KiB、phase1 profiler+fixture30KiB目安、本書8KiB目安。出力8MiB/空き5GiB、EXE1MiB/report256KiB、model32MiB/phase64MiB/WS・private各160MiBはphase2で別照合。最大2frame、旧frame1048861Bをencoder/BWT source estimateへ加算。guardはquota/peak保証ではない。

今回GOAL未達・activeのまま。計器タイミングを正式速度、確定CPU割合、oldsoftCTS率へ流用しない。Git/version/API/x86/外部/削除/追加委任0。
