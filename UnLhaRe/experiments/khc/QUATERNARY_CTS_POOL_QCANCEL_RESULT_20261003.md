# pool Q-cancel結果: 正しさ合格・性能基点への採用見送り

## 結論

同一binaryのdepth5旧/新/新/旧ABBA1周は、全frame bytes・全plain・全Proof（CDFのto_bitsを含む）・stats一致に合格した。ただし新Bはencode平均だけ短く、decode平均は長かった。本契約の両方向短縮条件を満たさないため、Q-cancelを次研究の基点に採用しない。基点は従来のdepth5・旧poolのままとする。数字を良く見せる再測定はしない。

これは1周・各2回・warmupなしの診断であり、統計的な悪化/改善も正式速度も確定しない。製品・API・wire・versionへ反映していない。goalはactiveを維持し、7-Zip総合超えや完了としない。

## 固定証拠・実行

親契約 `QUATERNARY_CTS_POOL_QCANCEL_CONTRACT_20261003.md` SHA06A85DD8249773BA8E1875122E4720DA8318B3C5FD1BB761F7D7DEE36289F8BA。reportは `build/khc-quaternary-cts-pool-qcancel-20261003/report.json` 343353B/SHA9754D28B1A1B896CE3DE0D032718AEDAEBB6CCC37164A5653417C715762E38FC、EXEは同root `pool-o2-yes.exe` 477696B/SHAFDF4307CE825B9105CFFBAFCA2D70C8FFDE6F5D2127FBF4EB68EA11B40A78653。

Windows 11 Pro 10.0.26300/x64、AMD Ryzen 5 7640HS（6core/12logical）、PowerShell7.6.5、rustc1.98.1 (48a229cea 2026-09-01)。compiler/runtimeのSHA、CWD、CPU/OSはreport.environmentに記録。compileはedition2024、frame_audit/primitive_audit、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、/DEBUG:NONE。Execute1/compile1/compare-snapshot1/compare-pool1/selfcheck1/selfcheck-new1/abba1で、候補CLIは5回、再試行なし。

親は旧runnerからの全差分、Rust5件、旧新codec許可置換と全Proof constructor、validator ASTを確認。独立analystも同じ最終5Rust hashを読み取り専用で検証し、成立する不具合なしと返却した。workerのPS parser/Rustfmt stdout9/nonExecute合格を経て親がExecuteした。compileにはunused-import警告3件（凍結CTSの2件と新poolのUpdate再export1件）があり、CLIのstderrは空だった。非実行preflightではコメントvector(q)の誤検出を1度修正したが、候補compile/CLIの失敗・再実行はない。失敗計画の内容・hashは確認済み、コードより先の保存順はworkerの報告であり、親の独立した時系列監査とは区別する。

## 正しさと直接比較

- q fixture20件・active62成分、Hamilton residual masks [1,3,6,15]、全p要素の旧汎用normalize対新helper一致。k3 residual0は数学上非該当。親の別BigInteger診断でも20件の商・余り共通Q倍率とsum=DQを確認。
- primary Prediction104 +拒否後再Prediction12=116、Update257を全field直接比較。uniform/BigInt正負/rare q0とfactor・gradient0/next不変を維持。12拒否のErr文字列・優先順・拒否後Snapshot全field不変を確認。
- compare-snapshot: sealed392成功/223拒否/22 failed observation、depth[4,5,6,7,8]は成功30/拒否1070/failed90/pure5/constructor2/compact60で旧固定件数に一致。
- 旧新各selfcheck: plain70/canonical70/malformed165/short20/model named70/assertions80/CAP5。frozen mid E2E/modelを別aliasでそのまま実行し、拒否後全state一致・CAP・原子性を維持。
- ABBAは入力2811006Bを1回読み、4回encode/decodeと全plain比較（計11244024B）。各往復全Proof/stats4回、first Aとの全Proof/stats3回、全frame直接比較3回・1436250B。hash-only、JSON丸め、digest-onlyを直接比較の代用にしない。

4frameとも478750B/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37、CDF3820763.985142052。固定grammar/count/classes・nodes1365/class・CTSnode196560Bも一致し、size<=483599Bを4回通過した。全Proofの直接EqはCDF bitsを含む14fieldを比較した。

## ABBA観測値

| index | 実装 | encode ms | decode ms |
| --- | --- | ---: | ---: |
| 0 | old A | 5580.2415 | 5365.0693 |
| 1 | new B | 5509.3920 | 5462.0797 |
| 2 | new B | 5564.9751 | 5512.6804 |
| 3 | old A | 5588.4549 | 5410.6554 |
| A平均 | old | 5584.34820 | 5387.86235 |
| B平均 | new | 5537.18355 | 5487.38005 |

観測上encodeは約0.845%短縮、decodeは約1.847%増加。単発診断なので確かな性能差とは呼ばない。採用条件both_mean_directions_lower=falseで、poolの型/observe/q/scoring/CDFと旧基点を保持する。旧phase sample比率の現在時間への外挿も行わない。

## identity・容量・清掃

reportの118 sources before/afterと親のlive hash/bytes/UTCticks照合はmismatch0。EXE before/after/liveも一致。graph16 unique sources/17 edges/root12/unique destinations15、static body/validator guard合格。旧106/99/89/84/72/60/48の全loop・EXE・既存失敗証拠照合を維持し、旧Executeは繰り返していない。冗長旧identity配列の保存だけscalar化し、現在118件の完全identityを保持した。

最終生成物はEXE/report2件・合計821049B（約0.783MiB）。8MiB予算/EXE1MiB/report512KiB/予約1572864Bに収まり、終了時空き82080743424B（約76.45GiB）。report.disk_afterは最後のreport書込み前の観測であり、最終bytesは親のdirectory実測とrunnerの最終capacityから確認した。新source7件140870Bと親契約/本結果も小さな研究証拠として保持。

RAM frameはreference最大1枚478750B、currentを含むlive最大2枚957500B、cloneなし、最終references0。全process peakとは区別する。input/frame/plain/temp/bak/PDB/Cargo target/traceはディスク生成なし、用途済み一時物なし。親のlive codec processは0。固定入力と再現証拠は保存規約上削除しない。製品/x86/shared cache/既存dirty changesを変更していない。

## 次候補と残る条件

次はPERF-POOL-MATH-U64を単独で評価する根拠がある。readonly analystがfixed_math.rs:46,59,61を確認し、exp_negのmag<=2^55、rem<LN2<2^48、position<2^60、ln_scaledのpos<2^43を証明した。位置計算の商/余りだけchecked u64へexact縮小し、difference*remの補間はu128を保持する候補である。domain拒否・Err・切捨て・table/全frame/状態を維持できるが、compilerが既に同じloweringを行う可能性があり、実効効果は未測定。Q-cancelを混ぜず従来depth5旧poolを比較基点とする。PERF-ALPHAは別の未採用候補のまま。

opopの手順で性能効果と契約維持を分けて判定し、両方向短縮しない候補を基点へ採用しなかった。worker-high（要求/実効gpt-6.1-sol/high）1名が7file所有。analyst（要求/実効gpt-6.1-sol/medium）はpool_qcancel_auditがQ-cancel算術、pool_qcancel_code_auditが独立コード確認、pool_next_math_auditが次のMath候補を担当。親が契約・統合・実行・判定を所有。外部現在仕様・照会・書込みなし。

正式single-thread codec median<574.5624msとmachine CPU<=15%は本段階では測定していない。このdiagnostic encodeも正式閾値より大幅に長い。holdout/categories、Windows/macOS x64/ARM64 native、製品/API統合、全process peakも未検証で、7-Zip総合超えは未達。次段階へ進めるための具体的候補があり、goalはactiveのまま。
