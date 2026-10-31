# 完全Bayes prototypeのCPU帰属 — 実装前契約

前turnは新codec/decoder/E2E/実比較を完了したprogress。候補483,468 bytesだがfullencode4,937.9919 ms、native7z602.3128 ms、固定条件<574.5624msへ未達。約88.36%短縮が必要で、既存LZのCPU比率やCTS/u128というソース上の印象を新候補の原因へ読み替えない。

凍結候補EXE `4C4D9D66EA0DE8174BF436D7222BC5CCF8F42BD03EF7A1DCFE030FAAD8322ABD`、同時生成PDB `F043C0DEC33A093174DE08908BA735AD3BA2909520EF33584F92F4B9A671467F`、既存36checks/61CLI proof `0AE7EAB04A5E58DE91AB1F74912F332D1FF6F2FC95D3A29DC0030F22A7307E37`、新source/modules、fixedgroup/manifest/toolchain/harness/toolを前後hash lockする。PE CodeViewとnativeMSF7 PDB GUID/age/file名一致を解析時に必須確認する。新たに候補をcompileしない。

- 失敗条件: 非絶対path/reparse/既存work/output、凍結proof/hash不一致、group11entry不一致、timeout/nonzero/stdout JSON不一致/公開frame SHA違い、decode SHA/entry不一致、他WPR recording/idle判定不能/start-stop失敗、traceサイズ0または>512MiB、capture-PID重複/再利用/時間窓不一致、imagebase/size不一致、EventsLost/欠損stack/未復元compressed stack/PDB不一致/符号解決失敗。
- 既存WPR sessionは停止/cancelしない。idleを確認し自分でstart成功したCPU filemodeだけ、finallyで一度stopする。先にwarmup encode1回、録画下encodeは**1回のみ**。終了後decode1回で全byte/11metadataを照合する。収集下のwall/CPUは採否時間に使わない。source/default/wire/parameterは変更しない。
- rawETLを読み、PID/TID/QPCのsample keyとStackWalkを結合。ProcessStart/Stop・capturedUTC窓を照合してPID再利用を拒否する。全部のtarget samplesを分母に含め、OS/unresolvedを除いて比率を膨らませない。physical return addressはRVA−1で解決、inclusiveはsample内function重複を除き、重なったcaller/callee比率を加算しない。ETLX/DIA/NGENPDB/online symbolsを作らない。
- sourceは `causal-bayes-packed/{sample-cpu.ps1,analyze-cpu.ps1,verify-cpu.ps1}`、所有基点 `build/khc-bwt-causal-bayes-cpu-20260930/`。過去normalLZ capture/analyzer/reportは変更しない。新unit testなし、成功した実ETL解析と既存work/未検証capture/誤binary/誤ETL/誤PID集合/時間窓の6拒否を解析CLI E2Eで検査し成果物を保存する。独立読み取り役に集計/source/PE-PDB/hashを照合してもらう。
- private/state capacityとOS peak memory、configured codec threadsとsampled OS threadsは区別する。fresh source帰属から1つの実効性を反証できる案を選び、実装前に別contractを固定する。除算/近似/lookupが速いと予断せず、数式・frame完全同値を必要条件にする。depth/prior/context/coeff sweep、製品版/deps/version/Git/UnLha32Re/holdoutは触らない。
- traceとmatching pair/reportはCPU証拠として保持する。前turnまでpolicy拒否の清掃対象148 filesやworker-smokeに再試行しない。今回の使用済み小fixtureのみ通常の絶対範囲/ancestor/process確認をして清掃し、拒否時は回避せず最小限記録する。清掃制限をgoal blockerにしない。

## 中断後の追加契約 — public nearest symbolを原因と誤認しない

凍結候補の録画・復元・raw stack結合は成功したが、minimal PDBのLLVM出力にStartAddress/FileName/Lineがなく、約半数のIPが実際にはsuffix-sort命令なのにguard関数名へ帰属した。既存解析reportの成功はデータ結合の成功だけで、意味的なsource帰属は未達と扱う。過去reportは上書きしない。

- 同じ凍結source/modules/range/packed alphabetとRust 1.98.1、edition2024、opt3、panic abortを維持し、別の新規build基点でdebuginfo=2のmapping binary/PDBを1組だけ生成する。製品・凍結EXE/PDB・ETL・数式は変更しない。
- 既存EXEとmapping EXEの全実行sectionについてRVA/VirtualSize/全raw bytesの一致を独立に照合する。一致した場合だけ同一RVAを新pair自身のCodeView/MSF identity検証後に解決する。PDBのGUIDが違う事実を隠さず、元EXEへPDBを差し替えない。不一致なら既存IPを推測移植せず、このmapping案を不採用として記録する。
- symbolはaddressを覆う明示的なfunction範囲、またはsource行/inline情報を持つ場合だけsource帰属として採用する。public名だけのnearest結果はunverifiedとし、OS/未帰属を分母から除かない。guardラベルのdisassemblyと接尾辞sort sourceを照合する。追加compileの時間を圧縮性能改善とは呼ばない。
- source/hash/toolchain/argv/exitと両pair/section照合結果を新reportへ保存する。全frame byte一致と復元SHAも新mapping binaryで確認する。source帰属が立つまではCTS/Bayes/除算/guardを支配原因と断定せず、最適化を実装しない。

### mapping不一致時の別採取契約

実行sectionのVirtualSizeが155080対154952、raw SHAが`6BF313A35304047C9C4F0E6153656BC9162CCFBC66FA8D431C2C3F883DB5C3BD`対`0516C648AA364411053B35836FC4B574574A29D56D72FAC0CCEFEA37FCDF754D`で不一致。旧ETLへsource情報を移植する案は不採用。

新pair `map.exe` SHA `7B843CE202AD0A5493F2868946343F124D5B3CC126C6866CC008B5CCA0A56B0D` / `map.pdb` SHA `6C42626057721F5B677EDCD2DC1BF9BD78F6B6195FBCA72ACEB036E15CF77E4E`だけを、同じfull36checks/61CLIで検証後、新WPR録画で採取する。元pair・元trace・元reportは変更せず、全source式/設定不変とframe byte一致を必須にする。新profileは別machine codeのサンプルであり、元profileの同じ割合や元の性能時間へ読み替えない。録画warmup1/recorded encode1/decode1、owned stop/512MiB/全分母/stack/lifetime/PDB/no-clobber等の既存契約は維持。

LLVMのFunctionNameだけでは帰属しない。正のsource行とFileNameがないframeはunverifiedとして報告・集計から外すが、全CPU sample分母には残す。sourceのあるinline callerは独立に帰属してよい。assembly/std builtin等のpublic名は参考情報に留める。元minimal PDBの再解析はdata reconciliationのみというstatusで保存する。

### 独立監査後の拒否強化

監査で採取harnessのstdout JSON未照合と終了idle receipt不足が指摘された。共有capture-proof.ps1で固定全frame統計の全9fields/operation/実output長/exit/stderrを照合し、採取のwarmup/recorded/decodeと解析時の保存receiptへ適用する。録画の再実行はせず、保存された実stdoutの照合とWPRの現在idle観測を解析E2Eへ追加する。新E2Eはwrong-JSONの早期拒否と実minimal-PDB source-required拒否（child exit保存）も行う。新snapshot/provenanceで現在sourceを保存し、過去captureのsource hashを現在値へ読み替えない。現在idle receiptはcapture停止時点のreceiptと同一ではないことを明示する。以後の採取harnessはowned stopの直後にidleも照合する。

1個のkernel-only sampleがProcessStopよりQPC2161 ticks後（216.1us）でinvocationの終了前に存在した。すべてのsampleはProcessStart以前を拒否し、ProcessStop以後のuser IP/user stack/候補frameを拒否する。captured invocation内・同PIDの完全start/stop1組でkernel-onlyのteardownだけは分母に保持し、delay QPCとuser帰属なしを別配列に保存する。これを厳密なuser process lifetime内sampleと呼ばず、分母削除で割合を膨らませない。
