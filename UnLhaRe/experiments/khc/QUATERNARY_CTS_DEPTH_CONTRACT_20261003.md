# CTS depth sweep: 事前契約

## 目的・範囲・採否

全体goalは7-Zip総合超過、ストレージ節約。前段sealedはencode診断平均7.2313sで依然正式速度条件には届かない。今回、CTS深さ0/1/2/4/8の計算段数・node storage・実frame size・完全復元を比較し、モデル構造のtradeoffを実測する。数学的entropy推定だけでsize gateを判定しない。研究用新形式の実験であり製品API/default/wire/versionは変更しない。

固定size gateは実frame<=483599Bを維持。正式singlethread中央値<574.5624ms/機械CPU<=15%、holdout/categories/4native/productAPI統合は本段階では未検証。単発sweepの速さを正式値や採用確定の比較値にしない。候補は完全復元/安全性/sizeを満たすものだけ次の同条件ABBAに進める。全候補が失敗しても条件を緩めず、最小の反証を残す。

親は本契約・結果・実行・採否、worker-high一人は新規 `quaternary-cts-depth/` 8ファイル(integer_cts.rs,model.rs,codec.rs,e2e.rs,probe.rs,comparison.rs,verify-depth.ps1,FAILURE_PLAN.md)だけを所有する。先にFAILURE_PLANを作り、unit testではなくstandalone E2Eを実装する。旧証拠/製品/manifest/x86/Git stage commit push/外部書込みを変更しない。

## 凍結基点

sealed契約SHA622867411E6A90CDD491D3EF96DA7640D20F47015B2AF29FCCF4521DFB6F0B9D。
sealed結果SHA E69CDB4BFE47A9BF69DA131798FCE5D3FC018E4427B75BB4941C30CD8BF5820C。
sealed report SHA B2EA272A74F5484993A2DA0A6396CC620A6BD6EA697868AB5DA99B24BE24237B。
sealed EXE SHA FF3EA779B4A28A4EBE06465430B6F8747F7CE5475C4B76623199FA1E89E016F2。
sealed integer_cts SHA E953BBA82FE27C64C1588EE1E6D3A4C33E64E1DB28BB3E75A25ADF506601E496。
固定input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。
固定frame474730B SHA9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD。
Math/pool/KT/mixture/update_kernel/BWT/range/packed alphabetを凍結。旧sealed全72source identitiesと旧proof closureを前後/live確認し、旧Executeは繰返さない。

## depthパラメータとCTS

depthは0..8のusize。Cts::new(depth)は範囲外を `unsupported CTS depth` でallocation前に拒否する。classごとのnode数=sum(4^l,l=0..depth)、1/5/21/341/87381。checked shapeで6class分だけ確保する（Node24Bなら144/720/3024/49104/12582864B）。historyは従来u16/最後8childrenのまま、path(history)の0..=depthだけをgather/update/commitする。class baseは新node_countを使う。

RawSnapshotの固定9level arraysは維持し、unused raw/weights/kernel kt/mixed/massesをcanonical zeroにする。idsは既存pathの9件を保つ。kernel.depthが現在depth、leaf weightはそのdepthでQ/2。predict_kernel/update_kernelの式は変えず、depthを渡す。updateされたunused next weightsは保存しない。depth8は旧sealedと全RawSnapshot/nodes/history/obsが同じになることを直接比較する。

sealed visible/certified、pure &self、合法modifiedの旧predict fallback、current guard順、拒否時全state無変更を維持する。current guardの対象は0..=depth、全gather→active leaf→active各level昇順weight/raw→causal→seal。未改変のforeign depth不一致tokenを誤受理しない。これはorigin認証契約ではなく、foreign tokenのvisible全体をdestinationの現在predictへ合法交換して完全一致させる場合は、旧sealed同様fallback受理を維持する。certified origin depthを新たにboundして拒否する方式へ変えない。depth8の因果・数値同値を比較し、全depthのCAP exact、stale/tamper/invalid current/dual-invalid順/純粋性をE2Eで確認する。無cache/nonce/ownerID/unsafe。

Model::new(depth)だけ追加、pool/count/serial/audit/treeのnumericalbodyは保持。model rejection_checks(depth)はCAP seedの対象をactive pathにし、全stateを直接比較する。同じepochの成功/拒否契約を維持する。

## private wire

magic `KHQCID01`、fixed header40B。既存7u32 fieldsのoffset8..32とheaderCRC offset32は維持し、u32depthを36..40に置く。packed metadataは40以降（従来36）。headerCRCは[0..32]+[36..header_len]でdepthも含む。min/maxheader73/285、MAX_FRAME=1MiB+285。

encodeは明示depthを受取る。decodeはframe内depthを読み、そのdepthでModel/Ctsを生成する。隠れglobal/環境/CLIの外部depthに依存せず、decode呼び出しだけで選べる。short/magic→unsupported depth→既存fields/quotas/headerCRC/metadata/payloadCRC→semantic/CRCの順を固定する。unsupported9/u32MAXをモデル確保前に拒否する。旧magicは意図的に拒否し、既存artifactは変更しない。

depth8 bridge: 実新frame474734B、旧frame[8..32]24Bと新[8..32]を直接比較し、旧[36..]474694Bと新[40..]を直接比較する。magic/新depth4B/headerCRCは意図的差分。これでmetadataとpayloadを全byte同値確認し、新headerCRCとdepth8decodeも確認する。旧frameはnewdecoderへ直接渡さない。

## 固定standalone E2Eとsweep

comparison CLIはdepth8対sealedの固定seed合法sequence/全RawSnapshot+成功後全nodes/history/obs比較、各depthのconstructor非法/failedpredict無変更、snapshot/cross-depth/stale/CAP/current guards/dual-invalid refusalsを事前固定件数で検証する。合法modified snapshot受理は前段を保持する。全state比較後のdigestのみを残し、hashだけで証明しない。具体件数は実装前FAILURE_PLANに固定しrunner validatorと照合する。

selfcheck CLIは各depth[0,1,2,4,8]でnormal14/plain14/canonical14、malformed33（既存30+unsupported depth9/u32MAX+supported depth改変CRC未修復）のexact reason、model named14/assertions16/CAP1/CRC fixtureを実行する。depth_crcは合法depthを別の合法depthへ変えるだけでheaderCRC mismatchになることを実確認し、CRCのdepth被覆を証明する。また各depthでframeを36/37/38/39Bにtruncateしてbad frame magic/headerを4回確認し、short_depth_header_checks=4を保存する。既存e2eのoffset36→40、69→73、68→72、metadata rank位置69→73を新headerへ合わせ、scripted/model/payloadへ明示depthを伝播する。unsupported guardを新headerの定義通り検証する。full_input canonical再encodeはしない。

sweep CLIは固定順[8,4,2,1,0]で各depthencode1/decode1。入力と旧baselineは各1回RAM読込。各candidateframeをそのframeのdepthでdecodeし、plain2811006Bをinputと全byte直接比較、encode/decodeのtoken grammar/branches/class observations/base-pool digest/CDFを直接比較する。frame/header/payload byte数・CRC・CDFを結果に残す。各frame/plainをdropし次depthへ。depth8bridgeを最初に検証する。sizeを超えても数値/復元が正しければgate失敗として記録し、次depthへ進む。数値/安全性失敗は停止する。

全depth共通: runs889227、primary1762795、alphabet257、rank/length889227、escape742、branches2725772/1099568、grammar58735a2b7383d755、classes[889227,620240,1216305,889227,64372,145969]。depth8はpayload474449/新frame474734/header285、plainCRC433441561/payloadCRC3589341169、base-pool9128444225deabce、CDF3788636.714502990±1e-4。浅いdepthのpayload/base-pool/CDFは固定旧値に強制せず、encode/decode同値とactual gateで判断する。

計時はencode/decode call前→returnのみ、JSON/比較/drop除外。warmup0/repeat0/内側timer0。固定順・単発のcode placement/CPU scheduling biasを明記し、best depthの正式speed判定や旧meanとの直接改善率は出さない。

## 実行・容量

nonExecuteでsource pins/graph/PowerShellとRust構文/runtime/compiler/arch/旧72closure/容量を確認後、親Execute一回でrustc1.98.1 edition2024 frame_audit primitive_audit opt2 overflowyes panicabort debug0 DEBUG:NONE compile一回、comparison/selfcheck/sweep各一回。child120秒、stdout/stderr各64KiB、失敗kill/dispose、raw JSON/parsed evidenceをvalidate前に保存。閉鎖graphの実件数を固定し、compile対象を全部pinする。source/EXE前後SHA bytes UTCmtimeを保存・照合。

出力 `build/khc-quaternary-cts-depth-20261003` は8MiB上限、EXE1MiB+report512KiB=1572864B scalar予約、開始/終了guard、空き5GiB+予算。最終EXE/reportのみ。input/frame/restore/Cargo target/debug/PDB/temp/bak/raw traceのdisk生成なし。既存corpus/固定証拠/共有cache/x86は保持。guardはOS write quotaではない。root既存/reparse/混在は拒否、無制限再試行なし。

## opop観点（親）

Modernizer: 凍結runtime/依存維持。Normalizer: 明示depth+自己記述privateheader。Performance: 1..9level計算/node数の候補比較。Cleaner: 旧proof保持/新生成2件。Hardening: bounds/CRCdepth/current guard/seal/commit維持。Tester: prewritten failureとfullbyte E2E。Async: purepredict/child finally/RAM drop。Startup: CTS node storage減少を実測し全体peakは未検証と区別。Intel: ローカル凍結モデルで判断、外部現在仕様不要・非該当。私的形式の新設は全体新アルゴリズム研究の明示依頼範囲であり、出荷形式の移行/統合ではない。
