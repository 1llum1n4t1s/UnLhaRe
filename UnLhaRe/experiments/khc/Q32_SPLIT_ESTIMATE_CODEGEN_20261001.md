# split商推定の実生成コード確認

2026-10-01 Windows x64、凍結済みnumeric opt3 EXEを再コンパイルせず診断した。source名と命令の対応はsource/呼出引数/制御フローからの推論で、PDB symbolによる対応付けではない。

- EXE: `build/khc-split-estimate-quotient-20261001/audit-opt3.exe`、SHA256 `AA38F1F7E25DF0FFE10D1BC6769D1D78ECDBDF9F1955105ED5B0E9B5AC64B911`。
- helper SHA256 `D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966`。
- numeric report SHA256 `03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29`。56191 records、47 checks、31 CLI。opt2/3各2repeatと旧signed全4rawの16組fullbyte一致。
- LLVM objdump SHA256 `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA`。

再現コマンド（UnLhaReディレクトリから）:

```powershell
& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe' -d --no-show-raw-insn --start-address=0x1400026b8 --stop-address=0x1400029ef 'build/khc-split-estimate-quotient-20261001/audit-opt3.exe'
```

観測した主要命令:

```text
1400026c5: movq -0x10(%rbp), %rax
1400026c9: mulq -0x8(%rbp)
1400026cd: jo 0x140002894
1400026d3: movq %rax, %r13
140002716: testq %r13, %r13
140002719: js 0x1400027ba
140002722: cvtsi2sd %r13, %xmm0
14000272a: cvtsi2sd %r12, %xmm1
14000272f: divsd %xmm1, %xmm0
140002733: ucomisd %xmm6, %xmm0
140002737: movabsq $0x7fffffffffffffff, %r8
140002741: ja 0x14000275b
140002743: cvttsd2si %xmm0, %r8
1400027ba: movq %r13, %rcx
1400027bd: movq %r12, %rdx
1400027c0: callq 0x140002980
140002980: movq %rcx, %xmm0
140002985: punpckldq 0x1ba63(%rip), %xmm0
14000298d: subpd 0x1ba6b(%rip), %xmm0
140002999: unpckhpd %xmm0, %xmm1
1400029a2: addsd %xmm0, %xmm1
1400029a6: divsd %xmm2, %xmm1
1400029aa: cvttsd2si %xmm1, %rax
1400029c2: cvttsd2si %xmm0, %rdx
1400029ee: retq
```

前signed候補の選択前両cast算出とは異なり、分子r13のsignでwide関数呼出へ分岐する。small枝はsigned float変換/商変換を持ち、wide側のunsigned分割変換と二つの商変換を実行しない構造になった。これは静的制御フローの観測であり、実codecへのinline後の同構造、動的実行回数、速度改善、wide入力の頻度は未確認。small枝にも飽和/NaN検査と補正/certificate/fallbackは残る。wideの呼出コストで全体性能が悪化する可能性は残す。

親の独立再取得時CPUは単発2%、その後5観測0/16/16/9/3%。16%の観測があり、この確認を15%の性能preflight成功とは扱わない。測定にはcompare自身の別preflightと各child前後guardが必要。
