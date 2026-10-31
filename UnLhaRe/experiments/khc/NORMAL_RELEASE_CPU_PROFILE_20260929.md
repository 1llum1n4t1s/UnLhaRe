# 通常Release CPU profile — 2026-09-29

## 結果

通常の`group-encode`経路のCPU samplingで、処理時間のflat source-line attribution上位はBeam側BT4処理の呼び出し位置とBT5木挿入の呼び出し位置だった。新規候補を支持する構造上限は確認できず、Grok助言の実装前gateを通らないため、codec/parser sourceは変更しない。

## 再現条件

- 作業ディレクトリ: `UnLhaRe/`
- 入力: `build/khc-current-source-native-solid-20260923-group/all.group`（2,811,006 bytes, SHA-256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`）
- 設定: `group-encode <input> --algorithm beam --beam-model blended --beam-matches bt5 --beam-width 2 --beam-block 8192 --dictionary-mib 64`; Range entropy backend
- 環境: Windows 11 Pro 10.0.26300 x64、AMD Ryzen 5 7640HS（6 core / 12 logical）、Rust 1.98.1 / LLVM 22.1.8
- build: `cargo +1.98.1 rustc --locked --offline --release --example khc_lab -- -C debuginfo=2`
- Sampling: Windows Performance Recorder `CPU` profile、1 ms sampling、3 process runs、0 lost events。TraceEvent 3.2.6とmatching PDBを使ってsource linesへ解決。
- Run別process CPU: 1,142 / 1,178 / 1,145 ms、平均1,155 ms。各runのframeは483,130 bytes / SHA-256 `CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D`。

診断Release executable SHA-256 `AD4364A7D467DC9F9A132754773120719C2BC9B48C4EF790223FF703F637285F`、PDB SHA-256 `0EA369D24D372611438CFED78DEB95485B95FA8306736447095DC73B462AE669`（17,510,400 bytes）。Profile時のsource SHA-256:

| File | SHA-256 |
| --- | --- |
| `examples/khc_lab.rs` | `5DE9CF2722BA4DF9EADB5D3A24A950A7DF6E592B1F747665623E7803487330D7` |
| `experiments/khc/lz.rs` | `7A9089C03C42CBDD4384CC5CB102682F3307309F1CD55E316A2FF97A364ECF66` |
| `experiments/khc/bt.rs` | `986FEE875B7E12A4B0CB83223E4787BD4AD57153306EB72FD008F64FA319EA18` |
| `experiments/khc/mod.rs` | `F68BAA89E93D648E1E34D57AF11313DB4F42715B294430289758BC5B7758E0CA` |
| `Cargo.lock` | `5609FF1B12E6686747F4D14F01243D2BD3B8530DF733B072A489911F80C44D84` |
| `Cargo.toml` | `D6493E185DAF2C3A3031D3D9F6F9533493A77A4EE8631B51DEA60BF1DB46BCF8` |

診断Releaseの`group-bench --repeats 1`もexit 0で、11 entryの全byte往復を通過した。frameは同じ483,130 bytes。これは正しさ確認であり、診断buildのtiming値は性能採否に使わない。

## Sampling結果と解釈

全3,465 CPU samplesのうち、khc_lab module内のIPは3,056、source lineが解決したIPは3,055だった。

| Flat source-line attribution | Samples | 全process samples比 |
| --- | ---: | ---: |
| `experiments/khc/lz.rs:5170` (`beam_plan_bt4_active`呼び出し位置) | 1,064 | 30.71% |
| `experiments/khc/bt.rs:478` (`insert_const::<true,5>`呼び出し位置) | 1,038 | 29.96% |
| 上記合計 | 2,102 | 60.66% |

これはIPのsource-line attributionであり、inclusive phase時間でも、その呼び出し位置の処理を除去できる見込みでもない。release最適化によるinliningを含むため、Beam全体・木挿入全体の所要時間として読み替えない。通常ReleaseのWPR 5-run CPU平均は1,157.4 ms、診断Releaseは1,155 msだったが、同時paired比較ではないのでdebug-info buildの影響がゼロだったと断定しない。

## 実装前gate

既存通常Release比較ではencode 1,001.5268 ms対7-Zip 574.5624 ms、generic PGO比較でも941.7668 ms対591.2521 msだった。各候補の測定系列内で7-Zip時間に到達するには総encode短縮42.63% / 37.22%が必要。上位2 line bucketの60.66%を正確な排他的領域と仮定しただけの粗いAmdahl screenでも、両bucket内部の約70.3% / 61.4%削減が必要になる。この換算はsamplingと以前のbenchmarkを接続した目安であり、正式な性能予測ではない。

独立読み取り監査では、BT側はtree/root/childを前位置から継承するため単純な位置並列化に必要な状態複製が要り、既知のunique 5-byte key省略も楽観上限で総CPU約3.93%だった。Beam側はcandidate snapshot、位置frontier、Rep LCP cache、block価格cacheを既に共有し、親ごとのRep順序と過去種別に依存するedgeを省くにはparser状態変更を要する。BT frontier並列化の既知上限はencodeの約13.1–13.5%。いずれも単独で必要量に届かない。

BT5 32-byte AVX2比較（candidate encode −1.55% / +0.21%の順序別結果）、LZ 64-byte AVX2 chunk（+2.55% / +1.42%改善）、およびBeam単独の再利用案は既存screen/監査でno-go済み。名称を変えた再試行はしない。

## 終了状態

- 追加のcodec/parser実装、API/wire/default/version変更なし。
- 既存Release `group-encode` frame 483,130 bytes / SHA-256 `CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D`。
- ETL/ETLXとDbgHelp NGENPDB cacheの清掃は、専用artifact pathを検証し`Remove-Item -LiteralPath`で一括削除する手順がhost policyに拒否された。回避策は使わず保留。report以外の27 file・493,551,145 bytesを`build/khc-normal-release-cpu-sampling-20260929/`に保持する。WPRは停止、関連processなし、tree内reparse pointなしを確認した。policyが許可する場合に限り、この専用path内の一時trace/cacheと保存済みreference copyを再評価して削除する。
- 次の候補は、既存BT5・Beam双方で具体的に省く仕事と必要状態を示し、総時間37–43%削減の実現可能な上限を提示するまで実装しない。

## 2026-09-30 保存traceの再読

保存済み`symbolized-release-cpu.etlx`はformat version 75で、現在のTraceEvent 3.2.6から開くと「formats >= 78」が必要として拒否された。既存NuGet cacheのTraceEvent 3.1.21とNETCore.Client 0.2.510501を.NET 10.0.11のPowerShellへ読み込むと、変換・上書きなしに開けた。当時の記録にある3.2.6という版表記だけでは、保存されたETLXの読み込み経路を再現できない。

`TraceLog.Events`全体から`Windows Kernel / PerfInfo/Sample`を対象PIDで選別すると、次の結果となった。Dispatcher/ReadyThreadなど、CPUサンプル以外のstack付きeventは含めていない。

| PID | CPU samples | stackあり | leafがkhc_lab | 記録CPU ms |
| --- | ---: | ---: | ---: | ---: |
| 9856 | 1,145 | 1,144 | 1,002 | 1,145 |
| 25248 | 1,142 | 1,142 | 1,026 | 1,142 |
| 1116 | 1,178 | 1,178 | 1,028 | 1,178 |
| 合計 | 3,465 | 3,464 | 3,056 | 3,465 |

1 ms間隔・loss 0と、従来のsample数・module数を再現した。`TraceProcess.EventsInProcess`を使うと各PIDの終了境界にある1 sampleが対象外となり、合計3,462になるので、全eventからのPID選別と混同しない。`TraceEventStackSource`へ全種別のprocess eventを渡したtreeもCPU専用集計には使っていない。

診断moduleのPDB identityは`a467ce73-1ec6-41e4-9377-93376a1cfcea / age 405`。前回の会話で述べた「4,032 PDBをidentity照合済み」は誤りだった。`SymbolReader.PdbMatches`は非公開のinstance methodなのにstatic methodとして呼び、例外を握りつぶしていたため、その試行に有効な照合結果はない。今回のpublic native readerも`Dia2Lib.DiaLoader`の初期化で失敗したので、identity照合が成功したとは扱わない。

独立したファイル確認として、`build/`内の実在する4,032件の`*.pdb`を列挙したが、当時の正本PDBの長さ17,510,400 bytesと一致するファイルは0件だった。このため記録SHA-256の正本PDBは当該範囲に存在しない。また現行`examples/khc_lab.rs`、`experiments/khc/lz.rs`、`experiments/khc/mod.rs`のSHA-256はprofile時から変わっている。元binary/PDBによる関数・inline frameの排他帰属は再現できず、現行PDBで旧IPを解釈しない。既存`report.json`と当時のsource-line集計は履歴として保持し、新たな削減量の証拠へは拡張しない。
