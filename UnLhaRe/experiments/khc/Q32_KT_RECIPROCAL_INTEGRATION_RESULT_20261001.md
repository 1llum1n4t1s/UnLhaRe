# KT reciprocal統合結果と性能測定の停止

## 現在確認できた結果

Model proof `build/khc-q32-kt-reciprocal-model-20261001/report.json` SHA `4D06E360637DCB16F8422EA149295B3F5B23B7D067B70638885DA8172A679B84` は62checks/59CLI/107identities。独立BigInteger oracleの11267records/7histories/7classes/17levels×5fieldsを通常/forcedportable opt2/3で全byte照合、旧KT65536recordsのerror順も通常/portableで一致。tableはModel所有1個・実storage524296B、Node16B/Prediction544B。verifier SHA `254F95D35A6B11D5F52AC3D0EFD1D85EB64E2A527FCAEDF9E6FA13E80654CF76`。元helperは保持し、local cloneのaudit_bytes cfgだけを変更。通常codecにnumeric監査cfgは付けていない。

Codec proof `build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/report.json` SHA `010C42392454709F7EE7FD69B25150579D880B1A773BC9CC32B6430CB45E419A` は34checks/57CLI/81identities。通常/portableで7cases、旧frame/EncodeStats/復号の全一致、固定group相互cross-decode、native反復、代表5破損拒否、encode/decode no-clobberを確認。固定frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。両proofのsource/raw変化・timeout/exit不一致・所有tmp/reparseは0。独立oracleの再利用であり新しい独立作者監査や旧87項目全再実行ではない。

## 通常codecの実命令

native EXE218112B SHA `74704D097CC6D70E531086DE73A3311716E1C3F96CEB62F6A5794067331B99FE`。rustc1.98.1、edition2024/panicabort/opt3。同toolchain llvm-objdump SHA `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA`で通常EXEをdisassembleした。numeric CLIの命令を代用していない。

rootはoverflow/cap検査後に等カウントを迂回し、total<65536（d<=65536）ではtable参照とhigh multiply `0x14000a3fc`へ進む。後続levelも`0x14000a4ee/a4f5`でdomain分岐、`0x14000a50e`でtableをoperandとするmulq、high RDXを商に採用する。table枝には除算・商補正はない。大分母fallbackにはroot `0x14000a429`、後続`0x14000a465`のdivlが残り、表構築の除算も全CLI費用に含む。これだけではcache/分岐/初期化費用を含む速度優位性を証明しない。

```text
14000a3d0: 45 0f b7 54 2f 1c           	movzwl	0x1c(%r15,%rbp), %r10d
14000a3d6: b8 00 00 00 80              	movl	$0x80000000, %eax       # imm = 0x80000000
14000a3db: 39 ca                       	cmpl	%ecx, %edx
14000a3dd: 74 5c                       	je	0x14000a43b <.text+0x943b>
14000a3df: 41 8d 48 01                 	leal	0x1(%r8), %ecx
14000a3e3: 41 81 f8 00 00 01 00        	cmpl	$0x10000, %r8d          # imm = 0x10000
14000a3ea: 73 38                       	jae	0x14000a424 <.text+0x9424>
14000a3ec: 48 39 cb                    	cmpq	%rcx, %rbx
14000a3ef: 0f 86 87 03 00 00           	jbe	0x14000a77c <.text+0x977c>
14000a3f5: 48 c1 e2 20                 	shlq	$0x20, %rdx
14000a3f9: 48 09 d0                    	orq	%rdx, %rax
14000a3fc: 49 f7 64 cd 00              	mulq	(%r13,%rcx,8)
14000a401: 48 89 d0                    	movq	%rdx, %rax
14000a404: 48 8d 48 ff                 	leaq	-0x1(%rax), %rcx
14000a408: ba fe ff ff ff              	movl	$0xfffffffe, %edx       # imm = 0xFFFFFFFE
14000a40d: 48 39 d1                    	cmpq	%rdx, %rcx
14000a410: 76 29                       	jbe	0x14000a43b <.text+0x943b>
14000a412: 4c 8d 3d 0f 12 02 00        	leaq	0x2120f(%rip), %r15     # 0x14002b628
14000a419: 41 be 22 00 00 00           	movl	$0x22, %r14d
14000a41f: e9 35 02 00 00              	jmp	0x14000a659 <.text+0x9659>
14000a424: b8 00 00 00 80              	movl	$0x80000000, %eax       # imm = 0x80000000
14000a429: f7 f1                       	divl	%ecx
14000a42b: 89 c0                       	movl	%eax, %eax
14000a42d: 48 8d 48 ff                 	leaq	-0x1(%rax), %rcx
14000a431: ba fe ff ff ff              	movl	$0xfffffffe, %edx       # imm = 0xFFFFFFFE
14000a436: 48 39 d1                    	cmpq	%rdx, %rcx
14000a439: 77 d7                       	ja	0x14000a412 <.text+0x9412>
```

## 固定比較の準備と実行結果

`causal-bayes-q32-kt-reciprocal/compare.ps1` SHA `CE15DBEB417857C351A412ADF366C95511EEA00AFCCCA69FE228EDA2EF1C550C`。実行前のParser/AST照合で8helpers全文一致、計測loop/aggregationはcodec label/frame proof binding以外一致、旧85source pins保持（元self5pinsをnative32参照へcanonicalize）・追加込み97pinsのcurrent一致を確認した。旧proof predicates/DFSも保持し、新numeric/Model/codecを追加。source検査は親によるもの、新しい独立監査ではない。

2026-10-01T11:47:04.2789727Z preflight sample0 CPU14%はPASS、11:47:05.5960354Z sample1 CPU19%は15%閾値超過でFAIL。shell exit1。これは20:34頃の0〜9%観測とは別の時刻であり、後者を今回の負荷保証へ流用しない。今回の正式測定はencode/decode/native metadataとも0回、warmup0、9回測定0。preflightはwork確保より先なのでperformanceディレクトリもreport.jsonも作られていないことを実ファイルで確認した。上記はtool stdoutの停止記録であり、未生成の性能reportの代替成功証拠ではない。runtimeの全proof DFS・hold/afterまでは到達していない。

CPU guardは変更せず自動retryしない。candidate速度・旧実装比・7-Zip比を算出/採用しない。fixed size gateのみcorrectness段階で確認でき、strict encode574.5624msは未証明。今回のowned E2E証拠は合計64,326,596B、再現に必要なraw・report・EXEを保持し、tmp/reparse0。製品/x86/共有キャッシュ/CPU設定/外部write/Gitは変更していない。

## 残作業

新候補のquiet-host全CLI正式測定が未達。固定developmentの局所改善だけで全体勝利としない。holdout・カテゴリの圧縮率/encode/decode/peak memory・同境界/同資源条件・Windows/macOS x64/ARM64のnative・製品組込と安全性の確認は未達。全体goalはactiveのまま。次の変更は未測定候補を速度採用せず、実コスト/分布に基づくアルゴリズム改善又は条件変化を確認した新しい正式比較として分離する。
