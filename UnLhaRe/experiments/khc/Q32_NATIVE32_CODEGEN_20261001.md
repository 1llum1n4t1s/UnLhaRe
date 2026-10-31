# guarded64/32商の実EXE命令記録

2026-10-01、Windows x64/rustc1.98.1。通常数値EXEと通常codecのcurrent SHAを確認した上で、llvm-objdumpの全EXE逆アセンブル（命令境界から）を読んだ。部分アドレスから始めた初期出力の不正境界は根拠に使わない。

| 対象 | SHA256 |
| --- | --- |
| llvm-objdump.exe（同toolchain lib/rustlib/x86_64-pc-windows-msvc/bin） | B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA |
| native32 numeric opt3 EXE | 27A7DBB549A39B86C10D7063BB6F9EF449B1A466F490BAB1554BA3FF397EB6B3 |
| native32 full codec EXE | 44CF635A18CF73E14E968A63C5A0EC4534FE47A4E277D7F818C32E1EEDE740C3 |
| forcedportable full codec EXE | 5DC6E89B18C67F95DCC81CF8399E0E4F1198163633D7FBDA7034DCFE8B7606CE |

数値EXEでは0x140002c47の分母zero、c4f/c52のmul/overflow、c62/c65のQ比較後、cfe〜d08で積high32と分母を比較し、high>=dなら旧estimateへ進む。d0aの `divl %r9d` がEAX商/EDX残余を返し、d17で旧float/proof/correctionを迂回する。d4b以後のsigned変換/divsd・unsigned helper・整数proof/fallbackは残る。audit sourceは残余を観測するため同primitiveを再呼出しするが、このopt3ではpure asmが合流し、当該分岐の実命令は1個。通常codecはnumeric audit cfgを入れない。

全codecでは0x1400098ee/98f1の分母zero拒否、98fa/98fdの積overflow拒否、9903/9906のQ比較、9918以後のwide判定を経た後、99be〜99c8でhigh32<dを検査し、99caの `divl %r12d`、99cfのjumpで旧estimateを迂回する。不成立は99d4以後へ進む。命令とsource対応はoperands・定数・分岐構造からの推定で、PDBによる行番号帰属ではない。全EXEには8個のdivlがあるが、通常の32bit商処理/fallbackも含まれるため8個すべてを新経路とは数えない。

この記録が示すのは凍結EXEに分岐と命令が実在することだけ。hit率、cycle、wall time、分岐予測費用、メモリ負荷、native7-Zip比は未測定であり、高速化や採用を主張しない。

再現例（UnLhaRe/をCWD）: 同toolchainのllvm-objdump.exe `-d build/khc-bwt-causal-bayes-q32-native32-20261001/codec-native.exe`。全出力から0x1400098ee〜0x1400099e5を確認する。EXE/report/PDBは検証rootに保持。
