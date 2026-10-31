# Q32 CTS混合再利用の先行契約

前段split候補の全frame・モデルを保持し、predict/updateで同じ混合を二度計算する経路だけを削減する。速度は未判定で固定gateを緩めない。

## 失敗条件（実装前）

- stale/differentclass Predictionにcached分母を無条件使用し、旧live-weight式と不一致になる。
- Q32の各段zeroをQ15 root値と混同、remainder bit又はbit1補数の取り違え。
- Q^2をu64で作る、checked/probability/cap/error/no-clobberを失う。
- snapshot配列/返却copy/branchの増加で遅くなる。
- 数値oracleを実装と共有、Q15又は最終frameだけで分母/次weightの正確性を宣言する。
- 旧full71checks/130CLI、opt2/3、全frame byte一致/相互復号、readlocksが欠落。

## 方針

private APIの利用条件を狭めず、Predictionに16段のweight snapshot [u64;16]とremainder u16を保持する。predictで旧weighted_sumを一度だけ実行し、zero=floor(s0/Q)とs0%Q!=0を保存する。

updateでは旧node.weight/child補数/pk/child probability検査を保持する。live node.weight == prediction weight snapshotの段だけcached分母を使用する。bit0はchecked zero+[remainder]、bit1はchecked Q-zero。weightが異なる場合は旧weighted_sum/ceiling加算/divisionへfallbackする。これによりstale/differentclassでも同weightなら同じs0、違うweightなら旧式となり、単回codec経路の仮定だけに依存しない。pk/child/check/errorに無関係な変更やAPI変更をしない。newhelperはcached分母とlive-weight fallbackの双方を数値CLIから実呼出できるようにする。

snapshotの追加はメモリ/copy増加の費用がある。圧縮時の回避率を仮定せず、実codecの全CLI比較で評価する。将来のpacked snapshot等はこの候補へ混入させない。

## 所有と数値E2E

新experiments/khc/causal-bayes-q32-mixture-reuseのcts_model.rsとaudit_cli.rs、verify-numeric.ps1だけを担当一人が所有。CTS基点はsplit SHA87AD15A78B390FA3F34A2ED6C36DD19CEAC05E4B3D29979207BA9A11B52393EA。親はcodec/build/fullverify/性能入口/契約/文書を所有し、CTS凍結までcodec組込みを開始しない。

実helperを呼ぶCLIについて、独立PowerShell BigIntegerのs0、sbit/ceiling、floor posterior、nextweightと比較する。Q、weight0/Q/1/Q-1/Q/2、k/child1/Q-1/中間、remainder0/nonzero、bothbit、同/不同live weight、stale反例k3/c7/snapshotQ/2/liveQ/4を含む。決定的seedで有限追加境界も検証。各recordのraw分母/posterior/nextweightをopt2/3×2repeatで全byte照合。k/child0/Q、weightQ+1、denominator0等の拒否、既存出力保持、malformed/args/上限/timeout/ownedtmpをCLI実行で検証する。数値fixtures/oracleは同一実装を転用せず、rawとproofを保存し全source/compiler/input/oracle/outputのbeforeafter readlock/pinsを保持する。

sourceはapply_patch、Rust1.98.1/edition2024/panicabort opt3/2、出力root build/khc-q32-mixture-reuse-numeric-20261001/。新Rustskip_children fmtとParser。単体テストを作らず実CLI E2E、元source/proofを改変しない。製品/API/x86/Git/stage/commit/push/version/CPU設定/共有cache/外部書込を行わない。

helperだけでなく実Modelの配線も検証する。cfg(khc_mixture_reuse_audit)専用methodで実predict/updateを呼び、各段Q32 KT/zeroとvisited nodeの更新後count/weightをrawへ記録する。全class・交互/偏り・決定的seedの有限履歴を旧Q32数値E2Eの独立BigInteger疎木oracleで照合する。Q15一致だけで代替しない。audit専用methodは通常codecコンパイルの構造/動作へ混入させず、履歴数とraw形状をproofへ記録する。

数値・source独立確認後、実codecの旧全71checksに旧split7small+fixedのbyte/crossdecodeを加え、期待79checks/154CLI以上を保持。static演算削減を速度に読み替えず、旧split対照/nativeと同sessionでquiet15/warm1+9/circular/全CLI/元gateのまま測定する。旧splitの失敗performanceは正常化/部分採用/自動再試行しない。
