# CTS mid-depth: コード前固定の失敗計画

契約SHA76AD586F37805153938D5ED196B1FBC4F360693DF780D64640005999B3AAEC9Eに従う。新6ファイルのみ所有。旧CTS/model/math/pool/guard/seal/commit/wire/Accounting/計時bodyは凍結し参照する。ワーカーはPS parser/Rustfmt stdout/nonExecuteまで、型・compile・候補CLI・Executeは親のみ。

## 最小差分の失敗条件

probeはrepair基点のcodec/comparison pathをlocalへ変更し、sweepとJSON順だけ[8,7,6,5,4]に置換する。new_ctsの旧source pathとroot aliasは維持する。codecは旧depth基点からmodel pathだけ../quaternary-cts-depth/model.rsへ変更する（e2eは元と同じlocal path）。runner static guardで両sourceの全bodyを4/1置換後に直接比較し、他の差分は失敗。comparison/e2eはdepth列挙・固定形・JSON件数以外を変更しない。

## comparison 固定件数

sealed比較は392成功/223拒否/22 failed predict、seed1831565813/384stepsを維持。独立depthは[4,5,6,7,8]、各success6/pure1/visible tamper167/foreign拒否1/rebased合法1/CAP exact1。constructor拒否2、compact60=5depth×6class×history[0,65535]。

| depth | class nodes | node bytes | refusals | failed predict |
| --- | ---: | ---: | ---: | ---: |
| 4 | 341 | 49104 | 204 | 14 |
| 5 | 1365 | 196560 | 209 | 16 |
| 6 | 5461 | 786384 | 214 | 18 |
| 7 | 21845 | 3145680 | 219 | 20 |
| 8 | 87381 | 12582864 | 224 | 22 |

合計success30/refusal1070/failed90/pure5。旧8reason順と件数式[167,2,3,4,depth+1,3,2*depth+1,2*depth+3]を維持。全node区画・active ID・unused canonical zero・全RawSnapshot・成功後全nodes/history/obs・拒否/failed predict全state直接比較。理由・件数・CAP・priority・foreign/rebased・pureの相違は失敗。

## selfcheck 固定件数

[4,5,6,7,8]各normal/plain/canonical14、malformed33のexact reason、short header4、model named14/assertions16/CAP1、CRCfixture1。合計normal/plain/canonical70、malformed165/short20/model named70/assertions80/CAP5。正常/forge/scripted/offset/depth伝播を維持する。CRCdepth被覆、unsupported9/MAX、36..39short、旧magic拒否と全canonical frame/復元/audit一致を維持し、相違で失敗。

## sweepと回帰の失敗条件

順[8,7,6,5,4]、各encode/decode1、全calls/plain比較/stats比較5、input/baseline attempt/success各1。失敗時実績カウンタを維持する。plain2811006B全byteとProof/CDF bits/全stats直接比較。depth8旧frame bridge24B/474694B、新frame474734/header285/payload474449等は旧固定値。

depth4回帰はframe484023/header285/payload483738、payloadCRC2516407690/headerCRC3696859040、base-pool5bd5c61ec8da4195、CDF3862945.676275690±1e-4。runnerでencode/decode両statsを検査する。旧depth4frameのdiskコピーや全byte比較を主張しない。depth5/6/7のpayload/base/CDFに未知の旧値を強制しない。共通grammar/count/classes/plainCRCは元契約どおり。実frame<=483599のみgate、size失敗のみなら続行。数値・安全性・復元不一致は停止する。frame/plainは各候補後drop、diskコピーなし。単発診断は正式速度/改善率ではない。

## closureと容量

旧repair89sourceとEXEを新Immutable-Depth-Basisで前後/live照合、旧failed84/ sealed72/KT64 60/basis48も維持。旧result SHA EA766DEE84650FE530D51ABECCFCE2F2A9513DBE6407B13B411E91CA635CA1F8、report326925B/SHA96FF61D2B125982BCA413CC63EA86FA2DDCAC61AD7B157C744974E29FFC63DE2、EXE375296B/SHAE719F8B7237A200EEAE67CCBBAFC7B50EA5F489AA9F6AFAB31909772BA545A98をpin。旧89+new6+本契約+result/report/EXE3=unique99。compiled13sources/12edges/root10/unique12、RustSyntaxは旧CTS/model+新4Rustの6件。identity/source graph/root alias/minimal substitutionsの相違で停止。

新build/khc-quaternary-cts-mid-depth-20261003は8388608B上限、EXE1048576/report524288/scalar予約1572864B、空き5GiB+予算、開始/終了guard。nonExecuteでrootを作らず、親Execute1回・compile1・comparison/selfcheck/sweep各1。child120s/stdout stderr各64KiB、raw/parsed保存後validator、kill/dispose/finally、最終EXE/report2件のみ。既存root/reparse/混在/identity変化/容量超過は失敗。旧Execute・無制限retry・入力/frame/plain/temp/bak/debug/PDB/Cargo target/trace生成は行わない。

正式速度<574.5624ms/CPU<=15%、holdout、4native、製品統合は未検証。Git、外部書込み、version、x86、shared cache、子agentを扱わない。
