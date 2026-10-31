# CTS実書庫の計算回数診断

## コード前の失敗条件

- 凍結balanced CTS9CFC6DF121A3711D704ED9F36F8D068F03A788DBC9F1A67118BB0CA89BD2F647又はcodec9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680Bの演算・更新順・grammar・範囲制限・公開安全性を変える。
- 診断cfgなしの通常経路へcounter field/加算/branch/出力を残す。countを除去したsourceが元の処理と対応しない。
- KT各level、posterior各level、ceiling==pk、weight==Q/2かつceiling==pkの回数を混同する。整数のoverflow、checked境界、回数の整合不成立。
- 前処理だけの人工履歴割合を実書庫割合として使う、計測器付き時間を正式速度へ採用する。
- current input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、固定frame483469B SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95CのSHA/長さ/全byte不一致。
- 既存出力/rootの上書き、祖先reparse、source/current EXE pin不一致、compile/CLI失敗又は120秒timeout、復号相違、no-clobber sentinelの変更、source-after相違、証拠欠落。

## 所有と診断範囲

新directory causal-bayes-q32-operation-counts/{cts_model.rs,codec.rs,diagnose.ps1}だけをworker一人が所有する。凍結balanced sourceをcloneし、khc_operation_counts cfgでのみCTS Model/Treeへcounterを持つ。Cell等の診断専用保存でもよいが通常cfgには残さない。KT呼出しは成功後に総数/zero==oneを記録、updateの実ceiling・pk・node.weightが得られた場所でposterior回数/ceiling==pk/同条件かつweight==Q/2を記録する。各classのpredict/update数と観測bitsを出す。counter加算はcheckedとする。符号化modelへ新しい短絡はまだ加えない。

codecは依存を元codecと同じものへ固定し、CTSだけ診断cloneを参照する。encode_payload終了時の診断JSON1行をstderrへ出す（stdout既存Stats保持）。通常cfgには出力を入れない。全16非leaf×bitsのposterior件数、17×bitsのKT件数を確認する。7classesごとにsumし、予測と更新の一致・eligible<=identity<=posterior及びbalanced<=KTを検査する。

未使用root build/khc-q32-operation-counts-20261001にownershipと再現report、source/依存/compiler/contract/親数値・codecproofのcurrent SHA/readlockを保持する。opt3診断とcfgなしnormalをcompileする。normal encode1/診断encode2を固定frameと全byte照合、診断回数の完全一致を確認、診断decoderでnormal frameを復号して固定groupと照合する。normal/診断encode既存出力拒否とsentinel保持も検査する。安全な新root確保後の失敗はfailed reportで止める。作った一時物の用途・absolute pathsを残す。Git/外部/秘密/製品/x86/CPU設定を扱わない。

この工程は整数件数・書庫正確性のE2Eであり速度測定ではないためquiet-hostを採用条件にしない。通常CLI全9回の速度比較条件は別契約のまま維持する。時間・人工dataset・静的命令数から性能を推定しない。数値helper単独の全u64同値や新短絡の採用、holdout、総合7-Zip超えは後段未達。
