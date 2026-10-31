# signed推定候補の生成コード・組込み保留

凍結数値CLI opt3 SHA `4286CE1614F610BD900413C01663D7E8AF0B2B0BB4B0A6338343CE5D2800F867` を、同toolchain付属LLVM objdumpで再コンパイルせず読取診断した。圧縮候補や速度を測定した記録ではない。

## 再現

```powershell
& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe' -d --no-show-raw-insn --start-address=0x1400027a2 --stop-address=0x140002830 'UnLhaRe/build/khc-signed-estimate-quotient-20261001/audit-opt3.exe'
```

## 実出力

```text
Algorithm       Hash                                                                   Path
---------       ----                                                                   ----
SHA256          B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA       C:\Users\IMT\.rustup\toolchains…

UnLhaRe/build/khc-signed-estimate-quotient-20261001/audit-opt3.exe:	file format coff-x86-64

Disassembly of section .text:

0000000140001000 <.text>:
1400027a2:     	movq	%rcx, %xmm1
1400027a7:     	punpckldq	%xmm6, %xmm1    # xmm1 = xmm1[0],xmm6[0],xmm1[1],xmm6[1]
1400027ab:     	subpd	%xmm7, %xmm1
1400027af:     	movapd	%xmm1, %xmm0
1400027b3:     	unpckhpd	%xmm1, %xmm0            # xmm0 = xmm0[1],xmm1[1]
1400027b7:     	addsd	%xmm1, %xmm0
1400027bb:     	xorps	%xmm1, %xmm1
1400027be:     	cvtsi2sd	%r9, %xmm1
1400027c3:     	divsd	%xmm1, %xmm0
1400027c7:     	ucomisd	%xmm8, %xmm0
1400027cc:     	movabsq	$0x7fffffffffffffff, %rax # imm = 0x7FFFFFFFFFFFFFFF
1400027d6:     	ja	0x1400027dd <.text+0x17dd>
1400027d8:     	cvttsd2si	%xmm0, %rax
1400027dd:     	ucomisd	%xmm0, %xmm0
1400027e1:     	movl	$0x0, %r8d
1400027e7:     	jp	0x1400027ec <.text+0x17ec>
1400027e9:     	movq	%rax, %r8
1400027ec:     	movapd	%xmm0, %xmm1
1400027f0:     	subsd	%xmm9, %xmm1
1400027f5:     	ucomisd	%xmm10, %xmm0
1400027fa:     	movl	$0x0, %eax
1400027ff:     	jb	0x140002818 <.text+0x1818>
140002801:     	cvttsd2si	%xmm0, %rdx
140002806:     	movq	%rdx, %r10
140002809:     	sarq	$0x3f, %r10
14000280d:     	cvttsd2si	%xmm1, %rax
140002812:     	andq	%r10, %rax
140002815:     	orq	%rdx, %rax
140002818:     	ucomisd	%xmm11, %xmm0
14000281d:     	movq	$-0x1, %rdx
140002824:     	ja	0x140002829 <.text+0x1829>
140002826:     	movq	%rax, %rdx
140002829:     	testq	%rcx, %rcx
14000282c:     	cmovsq	%rdx, %r8
```

## 観測と判断

- 分子のfloat変換はpunpckldq/subpd/unpckhpd/addsdによるu64分割経路が残った。
- 同じdivsd商に対してsigned側cvttsd2si 1個、unsigned側2個が静的に現れる。非負・通常範囲の商では両側の計算を通り、0x140002829のn sign検査と0x14000282cのcmovsqで選択する制御フローである。
- sourceのifだけでは「signed側を通るとunsigned変換を実行しない」という狙いを生成コードへ反映できなかった。数値の正確性は独立監査PASSでも、処理削減を支持しないため、この形のcodec組込みを保留する。
- PDB関数名は未解決。ここはsource、checked積後のnを保持するrcx、float商と補正へ進む周辺制御からの帰属推論であり、動的時間やfallback頻度の測定ではない。codecへinlineした場合の生成結果は未検証。

次はwide unsigned推定だけをinline(never) helperへ分離し、small枝がsigned変換だけを使う制御フローを生成する一変数実験が候補。wide呼出の新costで悪化し得るのでcold属性や低頻度仮定は付けない。整数certificate/native fallbackを維持し、数値・flags一致と実生成コードを先に確認する。まだ実装・性能採用していない。全体目標と固定gateは維持し、総合7-Zip超過は未達。
