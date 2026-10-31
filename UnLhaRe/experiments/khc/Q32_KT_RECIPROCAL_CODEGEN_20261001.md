# KT reciprocal helperの実EXE high product

Windows x64/rustc1.98.1/ed2024/panicabort/opt3、audit EXE SHA `7EBDDBE4788239ACCDDE5061BA04F96367764F189B87B712DD8C9E44DC0DF585`。llvm-objdump SHA `B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA` の全EXE逆アセンブルで命令境界を確認した。source/operands/定数からの帰属推定で、PDBによる行番号帰属ではない。

0x140003000はMAX_OBSERVATIONS=0x21800043を検査し、302b以後でequal countsを分離。305bはtotal+1、305f/3066はtotal<65536のtable条件（d<=65536）。3068/306fのVec length境界検査後、3075/3079でdをindexとするu64 Rをloadし、307d/3081でKT numeratorのhigh/lowを組み立てる。3084でRをRAXへ、3087の `mulq %r8` が積をRDX:RAXへ返し、308f以後でRDX商のprobability boundsを確認する。table枝に除算・商補正はない。table初期化及び大分母fallbackの除算は残り、除算命令がEXE全体から消えたとは称さない。

0x14000274b等の時刻処理のmulqをKT high productへ混ぜない。auditはmethod/reciprocalも出力し、通常Modelへ統合後のcodegenとは別である。全327675domain/旧65536/boundary16の独立oracle照合、通常/forcedportable×opt2/3、repeat/format/cap/path/no-clobberを通過したnumeric proofは `9E6CE54D564C602CBAD6ACADFDF67D9AB0D2444B7C4791AC5383CDEAB63BBF93`。速度・hit率以外の費用・peak memory・native他OSは未判定。
