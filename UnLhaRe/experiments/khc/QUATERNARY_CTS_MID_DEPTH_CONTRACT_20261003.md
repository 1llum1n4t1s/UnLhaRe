# CTS mid-depth: 固定条件の追加比較契約

## 目的・固定基点

深さ0/1/2/4/8のsweepは完全復元・安全性が成立したが、size<=483599Bを満たしたのはdepth8だけ。depth4は484023Bで424B超過。本段階は未調査depth5/6/7を、既存depth8/4と同じbinaryで固定順[8,7,6,5,4]のencode1/decode1ずつ比較する。size条件、正式速度<574.5624ms/CPU<=15%、holdout/4native/製品統合の未検証を変えない。単発診断を正式値・改善率・最終採用に読み替えない。

凍結基点は `QUATERNARY_CTS_DEPTH_RESULT_20261003.md` SHA256 EA766DEE84650FE530D51ABECCFCE2F2A9513DBE6407B13B411E91CA635CA1F8。成功report326925B/SHA96FF61D2B125982BCA413CC63EA86FA2DDCAC61AD7B157C744974E29FFC63DE2、EXE375296B/SHAE719F8B7237A200EEAE67CCBBAFC7B50EA5F489AA9F6AFAB31909772BA545A98。成功source89件、failed source84、旧sealed72/KT64 60/basis48をSHA/bytes/UTCmtime前後/live照合する。旧Executeは再実行せず、元の失敗証拠も保持。

## 所有と変更範囲

親は本契約・レビュー・実行・結果を所有。worker-high一人は新規 `quaternary-cts-mid-depth/` 6ファイルだけを所有する（FAILURE_PLAN.md、probe.rs、codec.rs、e2e.rs、comparison.rs、verify-depth.ps1）。FAILURE_PLANを先に書く。旧全source・証拠・製品・manifest・version・Git・外部書込み・x86・shared cacheは変更しない。必要な前段テンプレートの新候補へのCopy-Item再利用は可、その後の編集はapply_patch。新しいバックアップや大型データコピーではない。

CTS/modelは前段のsourceを直接参照して複製しない。predict/update/pool/math/tree/BWT/rangeの数値body・snapshot seal/guard/commit・wireKHQCID01/depthheader40B/CRC・計時・Accountingはすべて凍結。

新rootはrepair probeと同body、codec/comparisonのpathを新localへ変更。new_ctsは元depthのまま、`use reference_cts as integer_cts;` を維持。sweep順・表示depth_orderだけ[8,7,6,5,4]へ。codecはmodel pathを旧depthへ、e2e pathを新localへ変更するだけで数値bodyは変更しない。decodeはframe内depthだけを読む。

## 実装前に固定するE2E

comparisonのnumerical/body/guard probesは前段と同じ。旧sealed対depth8の392成功/223拒否/22failed predictも維持する。depth別の範囲・compact形・JSON件数だけ以下へ変更する。

| depth | class nodes | CTS node bytes | successes | refusals | failed predict |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4 | 341 | 49104 | 6 | 204 | 14 |
| 5 | 1365 | 196560 | 6 | 209 | 16 |
| 6 | 5461 | 786384 | 6 | 214 | 18 |
| 7 | 21845 | 3145680 | 6 | 219 | 20 |
| 8 | 87381 | 12582864 | 6 | 224 | 22 |

合計success30/refusal1070/failed90、pure5、constructor拒否2、compact shape60=5depth×6class×history[0,65535]。reason順と各depthの件数式は前段のまま。全node区画・active ID・inactive zero・拒否時全state無変更・foreign/rebased契約・CAP・priorityを維持する。

selfcheckは[4,5,6,7,8]の各normal/plain/canonical14、malformed33 exact reason、short4、model named14/assertions16/CAP1。合計70/70/70、malformed165/short20/model named70/assertions80/CAP5。正常/forge/scriptedのbodyとoffset・depth伝播を変更しない。

sweepは[8,7,6,5,4]でcalls/plain比較/stats比較各5。入力/旧baseline各attempt/success1。全plain2811006B直接比較とProof/CDF bits/全stats直接比較を維持。size失敗のみ記録して続行、数値・復元・安全性失敗は停止。frame/plainは各候補後dropしdisk保存しない。depth8の旧frame bridge24B/474694Bとframe474734B/header285/payload474449等は前段値を固定。

depth4は前段とsame numericalbodyなので、frame484023B/header285/payload483738、payloadCRC2516407690/headerCRC3696859040、base-pool5bd5c61ec8da4195、CDF3862945.676275690±1e-4を追加regression guardにする。このguardは保存旧frameとの全byte直接比較を意味しない。depth5/6/7のpayload/base/CDFは旧値へ強制せず、encode/decode同値と実size gateで判定する。全depth共通grammar/counts/classes/CRCplainは前段値を維持。

## runner・容量・完了条件

元repair runnerを基に、旧source89closureを保持し、新6source＋本契約＋前段result/report/EXE3を加えunique99とする。旧89成功report前後/liveとEXE前後/liveを新Immutable-Depth-Basisで確認し、旧84failed等も引き継ぐ。root alias missingをstatic guardで拒否する。compiled graphは新root/codec/e2e/comparison＋旧CTS/model等の13sources/12edges/root10/unique12、全sourceをpinする。

static差分guardで、probeは2module pathと5件depth順の置換以外を変えていないこと、codecはmodel pathだけの置換でbodyが同一であることを直接比較する。comparison/e2eはdepth範囲・形・件数表示の差分を親が読む。PSparser/Rustfmt stdout6件（旧CTS/model＋新Rust4件）/nonExecuteまでworkerが確認し、型・実行は未検証として返して編集停止・所有返却。

親は合格後に新rootでExecute一回、compile一回、comparison/selfcheck/sweep各一回。rustc1.98.1 edition2024/frame_audit/primitive_audit/opt2/overflowyes/panicabort/debug0/DEBUG:NONE、child120秒/stdout stderr各64KiB、raw/parsed保存後validator、kill/dispose/finally、identity・容量の前後guardを維持。無制限retryや古いrootへの上書きはしない。

出力 `build/khc-quaternary-cts-mid-depth-20261003` は8MiB、EXE1MiB/report512KiB/予約1572864B、空き5GiB+予算。最終EXE/reportのみ。input/frame/plain/temp/bak/debug/PDB/Cargo target/traceのdisk生成0。元証拠も保持する。正式比較と総合達成は未検証のまま、合格候補の同条件ABBAを次工程とする。
