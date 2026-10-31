# CTS sealed snapshot: コード前の固定失敗計画

親の改訂契約 `../QUATERNARY_CTS_SEALED_CONTRACT_20261003.md` (SHA256 `622867411E6A90CDD491D3EF96DA7640D20F47015B2AF29FCCF4521DFB6F0B9D`) に従う。新規8ファイルだけを所有する。旧source/証拠、製品/API、manifest、x86、Git、外部サービスは変更しない。これは非公開研究型であり、旧RawSnapshot aliasとのRust source互換性はない。

## 反証と予測規則

- 未改変tokenでも古いstate、path、raw、weight、history、observationsなら拒否する。
- derivedのkt/mixed/masses/depthを含むvisibleの改変を、単純なseal不一致だけで拒否すると旧挙動を狭める。現在の旧predictとexact一致する合法改変は受理する。
- current guardsを旧順で全て済ませ、causal不一致を拒否する。causal一致かつvisible==certifiedは高速受理する。causal一致かつseal不一致の場合だけ旧predictでvisible全体を比較する。
- certifiedはprivateで、private constructor、visibleだけのDeref/DerefMutを使う。Default、from-raw、Deserialize、certified公開、unsafe、cache、nonce、owner IDは追加しない。
- prefix/class/child/CAP、current class、node index、leaf、level昇順のweight/rawの拒否優先順を維持する。dual-invalidでもtoken mismatchがcurrent guardを追い越さない。
- update_kernel、全9node準備、commit順、KT/mixture/kernel、モデル数値body、wire bodyを維持する。

## compare-snapshot の固定件数

LCG seedは `1831565813` (`0x6d2b79f5`)。試験はstandalone CLI一回で、unit testは作らない。巨大全state cloneは拒否/失敗probeのbefore/after確認に限り、成功sequence各stepは旧新のnodes/history/observationsを直接比較する。

| カテゴリ | 固定件数 | 内容 |
| --- | ---: | --- |
| 合法success sequence | 384 | 6class×4prefix×16step、LCG child、複数初期history、合法raw、weight 0/Q/2/Qの境界 |
| lifecycle success | 3 | clone、複数predict後の先行token、数値同stateの別Cts token |
| 合法modified success | 3 | fresh class0→1、prefixとderived一式交換、進んだcurrent stateへのvisible一式交換 |
| modified準備success | 1 | current stateを1step進める |
| CAP-1→CAP success | 1 | classと全path rawをCAP-1にseedしexact CAPへcommit |
| 全success state比較 | 392 | 各成功後の旧新全nodes/history/observations直接比較 |
| visible tamper rejection | 167 | kt/mixed/masses各9×4=108、depth1、raw36、weights9、ids9、history/observations/class/prefix各1 |
| stale rejection | 1 | clone採用後に元tokenを再使用 |
| class CAP rejection | 1 | CAP到達後のobserve |
| node CAP rejection | 9 | class未到達でもpath各level raw和CAP |
| invalid current rejection | 18 | leaf1、nonleaf weight8、raw和9 |
| dual invalid current+token rejection | 18 | 上記current異常とderived token tamperの組合せ |
| early guard rejection | 6 | prefix、class、child、token CAP、current CAP、current CAP+leaf不正の優先順 |
| 複数current guard優先順 | 3 | root raw超過+leaf不正、root weight超過+root raw超過、level1 raw超過+level2 weight超過。全件にderived token改変も重ねる |
| 全拒否case | 223 | 旧新exact reason、両者それぞれのbefore/after全state直接比較446回 |
| failed predict | 22 | prefix0/5、class上限、classCAP超、invalid current18、before/after44回 |

結果は上記件数、比較digest、snapshot bytes、CTS node storage bytes、拒否理由の固定要約だけをJSONにする。失敗はcase index/期待理由/実理由を1件だけ返し、raw traceは保存しない。ハッシュだけで全state同値を主張せず、digestは直接比較後の補助値とする。allocation失敗、破損index、pool後段失敗の実注入は新規追加しない。pool不正によるpredict失敗のstate不変は凍結model selfcheckに含まれる。

## 独立selfcheckとprofile

- selfcheck一回: 凍結integer-frame e2eのnormal14、byte roundtrip14、canonical14、malformed30のexact reason、model named14/assertions16、CAP success1、CRC32 fixture。model全state比較を保持する。
- profile一回: 同じbinaryでKT64/sealed/sealed/KT64のABBA4encodeとsealed decode1。fixed input2811006Bとprior frame474730Bを各一回RAMへ読み、各frame全byteとprior frame、restore全byteとinputを直接比較後dropする。追加warmup/repeat/full canonical再encode/内側timerはしない。
- full statsは全encode/decode runで親契約の全固定値を検証する。elapsedはencode/decode callだけ。平均が旧以上、bytes/state/reasonsが不一致なら不採用。速度やCPU15%の正式gate、holdout/categories、4native、製品/APIは未検証。

## runnerの失敗と保存

PowerShell parserを先に確認する。nonExecuteはfresh output rootを作らず、module graph、pin、旧KT64の全60identity closureと既存basis、compiler/runtime、capacityを検証する。SHA/bytes/UTCmtimeを開始終了で照合し、source lockはpath一意にする。新規source8件と契約、KT64結果/report/exe/runnerを固定する (runner自身はself identityとsource lockで固定し、自己SHA循環は作らない)。

Executeは親のみ、一回のcompile (rustc1.98.1/edition2024/opt2/overflow yes/panic abort/debug0/DEBUG:NONE/frame_audit/primitive_audit) とcompare-snapshot/selfcheck/profile各一回。各child120秒/stdout・stderr各64KiB。timeout、異常exit、unexpected stderr、parse/validation失敗はkill/dispose後、bounded raw JSON/partial evidenceを保存して停止する。旧compare-ktのvalidatorは新比較に流用しない。

出力は `../../../build/khc-quaternary-cts-sealed-20261003` に最終EXE/reportだけ。8MiB上限、開始/終了disk guard、空き5GiB+予算、生成前EXE1MiB+report512KiB=1572864B scalar予約。input/frame/plain disk copy、PDB、debug、temp、bak、raw trace、Cargo cacheは作らない。EXE/source identityの変更、pin/graphの不足、出力root既存/reparse、容量不足、異なるruntime/compiler/archを拒否する。guardはOS quotaではない。失敗時は再試行せず必要な最小bounded証拠だけ保持し親へ渡す。
