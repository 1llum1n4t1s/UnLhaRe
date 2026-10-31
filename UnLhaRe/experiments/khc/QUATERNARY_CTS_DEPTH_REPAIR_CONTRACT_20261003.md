# CTS depth: 実行入口の修正契約

## 確認済みの失敗と範囲

元の深さ別候補は事前確認に通過したが、2026-10-03T08:11:53.2563807Z～08:12:00.5893707Zの一度のExecuteでcompileに失敗した。凍結済み `quaternary-cts-integer-pool/integer_pool.rs:3` の `use crate::integer_cts;` に対応するroot aliasがないことがrustc E0432で確認された。候補CLI・圧縮・復元は0回で、性能は未測定。

元の8 source・事前契約・失敗reportは変更しない。失敗reportは `build/khc-quaternary-cts-depth-20261003/report.json`、124513B、SHA256 `9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0`。source84件の前後識別値を含み、EXEは生成されていない。元の出力先への上書き・再Executeは禁止。

修正候補 `quaternary-cts-depth-repair/` は新規3ファイルのみ（probe.rs、verify-depth.ps1、FAILURE_PLAN.md）。worker-high一人が3ファイルを所有し、親は本契約・静的レビュー・nonExecute・Execute・結果を所有する。旧codec/CTS/model/e2e/comparison/数学/BWT/rangeは元sourceを直接参照し、複製も編集もしない。失敗計画はコードより先に保存する。

## 修正内容と維持する条件

新root probeは元probeと同じbody、旧codec/new CTS/comparisonへの3つのpathを `../quaternary-cts-depth/` に変え、凍結sealed入口と同じ `use reference_cts as integer_cts;` を追加する。poolが呼ぶvector/normalizeなどの凍結数学をroot名へ公開するだけで、CTS深さ・数値式・状態・wire・計時境界・実績カウンタを変えない。

元契約 `QUATERNARY_CTS_DEPTH_CONTRACT_20261003.md` SHA256 `3B2A9E1CA7DF9FDE77DFECCD36CA93D7E513392ECA648B8EC9627180574450F3`、元FAILURE_PLAN SHA256 `36F8694E673D91BBDF2978053C56B8D37ADC4A6B99709478F916D381B28A0203` の全件数・条件を維持する。深さ0/1/2/4/8、size<=483599B、depth8新frame474734B、旧frame metadata/payload bridge474694B、full plain2811006B、comparison392/223/22と深さ別30/993/60、compact60、selfcheck70/165/20、model assertions80、CAP5を変えない。foreign-depth/rebased token、CRC depth、拒否順、無変更、pure予測、成功/失敗時実績カウンタも維持する。

## 証拠・実行・容量

元runnerを基に、元pinsは元ディレクトリ基準で解決する。元runner自体のSHA `A4C50C09A0C7EA5DB9337704F35315E1402C67609ADEBFFDE3737DB32D73F343` もpinに追加する。元84 source closureに新3ファイル・本契約・元失敗reportを追加してunique89とする。前後/liveのSHA/bytes/UTCmtimeを照合し、元失敗reportの84件が現在も同じこと、compile失敗・候補CLI0・EXEなしも検証する。旧sealed72/KT64 60/basis48は維持、旧Executeは再実行しない。

compiled graphはrootだけ修正版、残り12 sourceは元の凍結source。13sources/12edges/root10/unique destinations12を維持する。static guardでroot aliasの存在を追加検査し、compile対象全件をpinする。PowerShell parser/Rustfmt stdoutとnonExecuteで確認し、型検査と実行は未検証と区別する。

親が新rootでExecuteを1回だけ行い、rustc1.98.1 edition2024/frame_audit/primitive_audit/opt2/overflowyes/panicabort/debug0/DEBUG:NONEでcompile1回、comparison/selfcheck/sweep各1回。child120秒/stdout・stderr各64KiB、失敗kill/dispose、rawとparsed証拠をvalidator前に保存。無制限再試行はしない。

新出力先 `build/khc-quaternary-cts-depth-repair-20261003` は8MiB、EXE1MiB+report512KiB=1572864B予約、前後guardと空き5GiB+予算。最終EXEとreportのみ。input/frame/restore/debug/PDB/Cargo target/temp/bak/traceは生成しない。元失敗証拠124513Bを保持し、共有cache/x86/既存証拠は触らない。容量guardはOS quotaではない。

単発sweepは正式benchmarkではなく、速度改善率や7-Zip超過を主張しない。sizeと完全復元・安全性を満たした候補だけ次の同条件ABBAへ進める。正式速度<574.5624ms/CPU<=15%、holdout、4native、製品統合は未検証のまま。Git操作、version、公開、外部書込みは禁止。
