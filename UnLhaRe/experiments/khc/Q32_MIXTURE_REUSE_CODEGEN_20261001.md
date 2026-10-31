# 混合再利用の実生成コード（Windows x64）

凍結candidate EXEをLLVM objdumpで再コンパイルせず診断した。EXE SHA `4B39B65E931479E151322E92E69198F3ED6A6A6A5E3F1DBFB389BC02DEF19446`、tool SHA `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA`。名前とsource帰属は引数/命令/制御フローからの推論であり、PDB対応ではない。

再現（UnLhaReディレクトリから）:

```powershell
& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe' -d --no-show-raw-insn --start-address=0x140009860 --stop-address=0x140009a50 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/candidate.exe'
```

主要命令:

```text
14000986a: movq (%r12,%r15), %rdx
1400098f8: cmpq 0x80(%r9,%r14,8), %rdx
140009900: jne 0x140009940
140009902: movq 0x210(%r9,%r14,8), %r13
14000990a: testb %r11b, %r11b
14000990d: je 0x1400099b6
140009921: movq %rdi, %rax
140009924: subq %r13, %rax
14000992d: jne 0x1400099db
140009940: movq %r10, %rbx
140009949: leaq 0x78(%rsp), %rcx
14000994e: movq %rbp, %r8
140009951: movq %rax, %r9
140009954: callq 0x14000a9c0
140009983: addq %r12, %r13
140009986: shrq $0x20, %r13
1400099b6: leaq 0x10(%r14), %rax
1400099bf: btq %rax, %rcx
1400099c3: adcq $0x0, %r13
1400099d5: je 0x140009dd6
1400099db: movq %rbp, %rax
1400099de: mulq (%r15)
```

live/snapshot weight比較から異なる側だけweighted_sumと推定する関数callへ進む。同じ側はbit1補数又はbit0 remainderの加算からposterior計算へ進み、分母用weighted_sum callを通らない構造が残っている。整数checked/probabilityとposteriorの乗算は残る。これはstatic支持であり、動的hit率や速度削減率ではない。

whole EXEのdivsd sitesは8個。64bit商推定4箇所とwide helper等の存在を静的に数えるだけで、動的回数を表さない。Predictionは数値cfgのsize_ofで544B、旧field合計408Bに比べ増え、candidate EXEも217600B（旧split216576B）になった。追加snapshot load/store/copy/branch費用を含む実CLI時間はまだ測定していない。4native、holdout、総合7-Zip超過の証拠ではない。
