# CTS depth: コード前固定の失敗計画

親契約 QUATERNARY_CTS_DEPTH_CONTRACT_20261003.md（改訂SHA256 3B2A9E1CA7DF9FDE77DFECCD36CA93D7E513392ECA648B8EC9627180574450F3）に従う。変更は本ディレクトリの指定8ファイルのみ。compile、候補CLI、Executeは親が一回だけ行う。ワーカーはRust構文（rustfmt stdout）、PowerShell parser、nonExecuteのみ確認する。unit testは追加しない。

## comparison 固定件数

depth8とsealedの直接比較は既存seed1831565813、合法384steps、success392、rejections223、failed_predictions22。成功後全nodes/history/observationsと全visible RawSnapshotを直接比較する。拒否とfailed predictionは両実装の全stateをbefore/after直接比較する。旧reason件数[166,2,3,4,9,3,17,19]を維持する。

独立した各depth [0,1,2,4,8] のprobeは次の固定件数。constructor非法は共通2件（9、usize::MAX）。各depth純粋predict1件は全stateと2回のsnapshotを直接比較し、inactive arraysのzeroと全9idsを確認する。追加のcompact形検証はdepth×class0..5×history[0,65535]の60件。全nodesの区画を直接照合し、active ID < node_count、全9ids、unused arrays zero、固定node_count[1,5,21,341,87381]とstorage[144,720,3024,49104,12582864]をassertする。

| depth | success | visible tamper | stale | class CAP | node CAP | invalid current / dual tampered | priority | early | foreign depth | total refusals | failed predict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 6 | 167 | 1 | 1 | 1 | 4 | 2 | 6 | 1 | 183 | 6 |
| 1 | 6 | 167 | 1 | 1 | 2 | 8 | 2 | 6 | 1 | 188 | 8 |
| 2 | 6 | 167 | 1 | 1 | 3 | 12 | 3 | 6 | 1 | 194 | 10 |
| 4 | 6 | 167 | 1 | 1 | 5 | 20 | 3 | 6 | 1 | 204 | 14 |
| 8 | 6 | 167 | 1 | 1 | 9 | 36 | 3 | 6 | 1 | 224 | 22 |

success6=stale準備1+合法modified(class/prefix/postprogress準備/postprogress)4+CAP exact1。全visible kt/mixed/masses108+depth1+raw36+weights9+ids9+history/obs/class/prefix4=167拒否。全拒否993、failed predict60、success30、pure predict5。inactive改変、stale、異なるdepth token、同epoch合法modified fallback、CAP exact、early/current guardの理由または拒否時state変更は失敗。priorityはleaf優先、同level weight優先、depth>=2ではlower-level raw優先を確認。

各depth reason順は旧8理由を維持し、固定件数は[167,2,3,4,depth+1,(depth==0?4:3),(depth==0?0:2*depth+1),2*depth+2+(depth>=2?1:0)]。同じprobeを追加せず上表の期待理由を具体化する。

## selfcheck 固定件数

各depth [0,1,2,4,8] でnormal14 / full plain14 / full canonical frame14、malformed33（旧30のexact reason+unsupported depth9/u32MAX+depth_crc）、short_depth_header_checks4（長さ36/37/38/39）、model named14 / assertions16 / CAP exact1、IEEE CRC32 fixture1。合計normal70、plain70、canonical70、malformed165、short depth header20、model named70/assertions80/CAP5。旧offset36→40、69→73、68→72を適用する。unsupported depthはfield guard/CRC/model確保前に拒否し、旧magicを区別する。depth_crcは他の合法depthにfieldだけ変更し、未修復CRCでheader CRC mismatchを確認。short depth headerはbad frame magic/headerを確認。malformed reasonが異なる、許容、復元不一致、CDF/grammar/observations/state digest不一致、正準frame不一致で失敗。

foreign-depthは未改変tokenを別depthへ渡したときの拒否。origin certificateへ所有者/depthを新しくboundせず、visible一式をdestination現行predictに合法交換したtokenは既存fallback意味どおり受理する。この交換は各depthの合法modified prefix検証に組み込む。

## sweep 固定件数

固定順 [8,4,2,1,0]。入力2811006Bと旧baseline474730Bを各1回RAM読み込み。各depth encode1/decode1、plain2811006B全byte直接比較、encode/decode stats全項目直接比較。depth8は新frame474734B、old/new [8..32]24B、old[36..]/new[40..]474694Bの実byte比較。各frame/plainは次候補前にdrop。full input canonical reencode、旧decoder、新frame/plain disk保存は行わない。

全depth共通固定runs889227、primary1762795、alphabet257、rank/length889227、escape742、branches[2725772,1099568]、grammar58735a2b7383d755、classes[889227,620240,1216305,889227,64372,145969]。depth8 payload474449/header285、plainCRC433441561/payloadCRC3589341169、base-pool9128444225deabce、CDF3788636.714502990±1e-4。浅depthのpayload/base/CDFは旧値へ強制しない。実frame<=483599Bのみsize gate。gate失敗でも正しければ続行、数値/安全性/bridge/復元不一致は停止。単発計時は正式speed/CPUや改善率としない。

失敗時のpartial accountingも実績を保存する。encode/decode呼出直前にcall数、全plain比較と全stats比較の完了時にそれぞれ比較数を加算し、計時区間へcounterを入れない。input/baselineはread attemptと成功数を区別する。bridge失敗でもencode実行1を残し、input open失敗はattempt1/success0/baseline0を残す。正常時はencode5/decode5/plain5/stats5、read attempts/success各1。成功record件数や固定1から未実行call/readを推測しない。追加CLI・失敗注入実行は行わず、制御flowを静的照合する。

## runner 失敗条件と容量

旧sealed72source closure、旧KT64 60、旧48basisをそのままSHA/bytes/UTCmtime照合し、一意なread locksを保持。新8ファイル、親contract、sealed結果/report/EXEを追加してunique84 identities。runner自身はSHA循環へ入れずselfidentityで固定する。compiled static import graphは13sources/12edges/root10edges/12unique destinationsを固定、未pin import/graph変更を失敗とし自動緩和しない。

child120秒、stdout/stderr各64KiB。失敗時kill/dispose、raw JSON/parsed証拠をvalidator前にreportへ保存する。EXE1MiB、report512KiB、予約1572864B、出力root8MiB、空き5GiB+予算。既存root/reparse/混在、identity変化、runtime/compiler/arch相違、graph/count相違、child timeout/出力超過、容量超過は失敗。終了guardも必須。nonExecuteは出力rootを作らず検証のみ。EXE/reportの最終2件以外を生成しない。

メモリはCTS node storageの計算値と全体peakを区別する。formal singlethread median<574.5624ms/CPU<=15%、holdout/categories/4native/productAPI、heap/write/sync fault injection、全体peakは本段階では未検証。
