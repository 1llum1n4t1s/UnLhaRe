# CTS depth root alias repair: コード前の失敗計画

修正契約SHA256 029D352BE256560D3DF641F7FC31D18390CD0E2A71F20C7FB877498A22025350を正本とする。新規3ファイルのみを所有し、元8ファイル・元契約・failed report・数学・モデルを凍結する。ワーカーはPS parser/Rustfmt stdout/nonExecuteまで。compile・候補CLI・Executeは親のみ。

## 最小変更と反証条件

元probeのbodyは保持し、codec/new_cts/comparisonの3 module pathだけを../quaternary-cts-depth/へ変え、use reference_cts as integer_cts;を1行追加する。旧root aliasを必要とする凍結integer_pool.rs:3へ同じreference_ctsを供給する。変更差分がこの4箇所を越える、旧8ファイルが変わる、root aliasが欠ける、実行body・カウンタ・計時・形式・数値式が変わる場合は失敗。

## 不変のE2E件数

元契約SHA3B2A9E1CA7DF9FDE77DFECCD36CA93D7E513392ECA648B8EC9627180574450F3と元FAILURE_PLAN SHA36F8694E673D91BBDF2978053C56B8D37ADC4A6B99709478F916D381B28A0203をそのまま参照する。sealed392/223/22、depth別30/993/60、constructor2、pure5、compact60、selfchecknormal/plain/canonical各70、malformed165、short20、model assertions80、CAP5を維持する。

sweepは[8,4,2,1,0]、各encode/decode1、合計calls/plain/stats各5、read attempt/success各1。失敗時実績カウンタを維持する。depth8新frame474734B、bridgefields24B、metadata/payload474694B、plain2811006Bの直接比較と全audit同値。size gate<=483599Bは不変、size失敗だけなら続行、数値・復元・安全性失敗は停止。正常ロジックの追加試験・再設計は行わない。

## source graphと凍結失敗証拠

元pinsを元root基準で解決し、元runner SHA A4C50C09A0C7EA5DB9337704F35315E1402C67609ADEBFFDE3737DB32D73F343を追加pin。旧failed84 identitiesを前後/liveで照合、新3ファイル+修正契約+failed reportでunique89。旧sealed72/KT64 60/basis48は維持する。

failed reportは124513B、SHA9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0、status failed/build-once、rustc compile1/exit1/E0432、candidate CLI0、EXE identitiesなし。元出力rootはreport.json1件のみを検査し、元rootを再Executeしない。source/EXE/runner/failed reportのidentity相違・旧CLI再実行・旧root混在は失敗。

compiled graphは修正root+元12source、13sources/12edges/root10/unique12。全compile対象をpinし、alias存在と最小probe差分をstatic guardで照合。RustSyntaxは元5Rust+新probeの6件、stdoutだけで書き戻さない。type/実行の確認には扱わない。

## 容量と実行境界

新出力先build/khc-quaternary-cts-depth-repair-20261003、上限8388608B、EXE1048576B/report524288B/scalar予約1572864B、空き5GiB+予算。nonExecuteでrootを作らない。元失敗reportを保持。新root既存・reparse・混在・容量超過で停止する。親Execute1回、compile1、comparison/selfcheck/sweep各1、child120s/stdout stderr各64KiB、raw/parsed保存後validate、kill/dispose/finally identity/guardを維持する。最終EXE/reportのみ、入力/frame/plain/temp/debug/PDB/Cargo targetを生成しない。

型と実行、正式速度<574.5624ms/CPU<=15%、holdout、4native、製品統合は未検証。Git stage/commit/push、version、公開、外部書込み、シークレット、x86、共有cacheは扱わない。
