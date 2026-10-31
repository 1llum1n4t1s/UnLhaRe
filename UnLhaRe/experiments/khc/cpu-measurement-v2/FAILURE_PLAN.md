# CPU measurement v2: failure-first contract

保存順: この文書を新helper/runnerより先に保存。所有はこの文書、run.ps1、examples/khc_speed_probe.rsのみ。製品/旧実験/旧runner/旧helperは凍結保持する。

正常系happy: 同じRAM rawで旧/新paid encode全byte一致（Base64の厳密比較）、各decode元byte一致、初回fixtureで旧frame→新decode/新frame→旧decode一致。empty/1byte/repeat4096/all256*8/seeded65536/alice29/kennedyの7fixture。正常のみの測定器であり、製品の異常frame E2Eは既存担当へ残す。任意のall.group3blockは時間内の最小scopeから除外（省略を報告）。warmup1+9、旧新順交互、全sample保存。各fixtureの元SHAとsource/windowを保存しraw/frameのdisk保存0。

失敗分類: encode byte差/自己復号差/相互復号差はHIGH product defect候補（helper provenance差も確認）。SHA/mtime/source変更、未知CLI、入力上限、child終了非0はenvironment/contract error。async Task<void>出力漏出、pipe deadlock、上限検査漏れはtest defect。候補は停止し失敗理由・途中sampleを保持、成功扱いしない。native実行は親のみ。本workerはsyntaxだけ。

resource: 入力1MiB、frame1MiB+40、stdout1MiB+4096/stderr16KiB、child WS/private各64MiB、child60s/suite900s、CPU quiet<=15%で最大60s待機。各iterationでguardを確認、stdin close/read completionが進捗ならsleepせず、進捗なし時だけ10ms sleep。inner read loopなし。RAMはfixture1+旧新frame2+decoded一時のみ。stdout/stderrを非同期でdrainしWriteAsync(void)はnull代入。OSのpeak WSとpolled privateは短命childの最終peakを取り逃す可能性があり、純codec CPU測定ではない。

保存: unused build/khc-cpu-measurement-v2-20261005[-Attempt]/report.jsonのみCreateNew、report256KiB/output8MiB/free5GiB。既存出力を上書きしない。compile/sharedcargo予算は親（remaining71,610,815B、guard48MiB）。Git/削除/network/download/追加依存/追加委任0。

由来: helperは凍結examples/khc_block_io.rsのpublic API wrapperを独立記述。runner Pin/Same-Bytes/Seeded/async binary pumpはproduct-comparison/run.ps1の構造を移植し、進捗フラグ、旧新比較、固定7fixture、900s/64MiB、CreateNewへ明示変更。旧sourceは編集しない。厳密同一copyではない新scopeの記述で、全native未検証。

source pins: 旧EXE固定SHA DAB84057869264AAD41E1AE8BD4CB01B97EB604BDBBBCB636706F6AEEAC971C3、新EXE親指定SHA、src/khc全Rust（CRCmod含む）・src/lib.rs・Cargo.toml/lock・helper/runner/本書・旧wrapper・2corpus。新sourceはCRC最適化後の状態を前後pinし、旧EXEのcompile source provenanceは親ledger（現在sourceを旧版と誤認しない）。7zip優位はこの測定で検証しない。以前の別runner速度は持ち込まない。
