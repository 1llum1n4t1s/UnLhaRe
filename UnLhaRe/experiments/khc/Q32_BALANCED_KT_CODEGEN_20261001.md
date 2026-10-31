# 等カウントKT短絡の実生成コード

新candidate SHA7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0、旧mixture control SHA4B39B65E931479E151322E92E69198F3ED6A6A6A5E3F1DBFB389BC02DEF19446をLLVM objdumpで再コンパイルせず確認した。tool SHA B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA。新context独立担当が実命令を追跡した。PDB帰属未確認、Node::kt/next_weightへの対応はフィールド・定数・式・制御フローによる推定である。

再現（UnLhaReから）:

```powershell
& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe' -d --no-show-raw-insn --start-address=0x14000a290 --stop-address=0x14000a600 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'
```

rootはa2aa addl→a2ad jb（overflow）→a2b3 cmp $0x21800043→a2b9 jbe a35c（cap内）。その後a372でQ/2をecxへ設定、a377でzero/one比較、a37f je a45cで商を計算せず保存先へ合流する。後続16levelもa4ef addl→a4f2 jb→a4f8 cmp cap→a4fe ja（超過）後、a504でQ/2、a509等値比較、a50c je a491で商を迂回する。いずれもoverflow/cap検査を通過した等カウントだけである。

非等値root a3a2 divsd、unsigned helper a3c9 call 140006b20、level a530 divsd/a5dd call同helperは保持。推定商の整数積・残余検証、上下1補正、失敗時native divも残る。rootはa3e9 mulq/a3f2 cmp/a3fc decq/a414 incq/a431 cmp/a444 divq、levelはa552 mulq/a56e decq/a5a2 incq/a5b7 cmp/a47e divq又はa5ce divl。旧root a3dc〜a40b、level a58d〜a5b4には等値分岐がない。全EXEの静的divsd8/native div16箇所は新旧同じで、動的頻度・高速化率を示さない。

追加の反証: next_weightの固定分母Q=2^32については新旧とも既に checked product→shift32である。140009b9d mov retained、9ba0 mulq posterior、9ba3 jo overflow、9ba9 shrq $0x20、9bad add alpha、9bb0 cmp Q+1、9bb3 jae bounds、9bb9 storeが同一。float estimate/generic proofは直前のposterior_ratio側であり、この固定分母側にない。exact_div.rsのd==Q短絡も現在sourceで確認した。明示的shiftへ書換える新候補は削減がないため実装しない。

private arbitrary argsの厳密な置換なら product overflow→shift→alpha checked_add overflow→weight>Qの順を保持する必要がある。retained=Q/posterior=Qは商がQでも積overflowが先であり、先行bounds検査へ置換しない。今回はコード変更なし。正式速度・動的hit率・4native・holdout・製品/総合目標の証拠にはしない。
