# 次候補：exp_negの2冪除算を反証する

## 対象と判断

現stageの4子sample生時間ではpool predictが最大だった。ただしN/n推計はwholeを超過しておりCPU割合を確定できない。pool predictは合法childごとにfloat_math::exp_negを呼び、現本文は補間値を動的な2冪で除算する。変換・除算を正確な逆2冪との乗算へ置換する限定候補を、採用前にbit同値・拒否・生成命令で反証する。追加heap・表・浮動加算順の変更はしない。

旧float_math SHA9349A09F011C051CBD3EB7927DAE509035EE86F2993991194536B7166C52F7F3、canonical fixed_math SHA A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD。全本文復元が1siteだけで一致することを実行前に確認する。旧guard/cutoff/grid/interpolation/result検査とerror順を保ち、exponent<32を確認した後だけinverse scaleを構成する。

候補式は `interpolation*f64::from_bits((1023u64-u64::from(exponent))<<52)`。全入力についての速度改善や全nativeのbit同値は未確認。LLVMが旧式を既に同等にしている場合、命令削減の根拠は棄却する。生成命令に差があっても通常codecの改善が保証されるとはしない。

## コード前の失敗契約

source/SHA/全文復元差、追加module/heap/式順変更、constructor失敗、有限正常bit差、Err文字列・Ok/Err分類差、signed zero/NaN/Inf/域外/境界/cutoffの差、counter/digest overflow、case数超過、無制限Vec、native timeout/compile/panic/保存/容量超過を失敗とする。

finite入口は同processに旧Mathと新Math各1個だけを生成。データcaseは逐次比較し保持しない。指数0..31×grid index0..4096の実dとnext_down/中心/next_upを393312件、LCG固定seed0x6d2b79f5で0..128の65536件、固定域外/NaN payload/±Inf/±zero/subnormal/128近傍/cutoff近傍の一覧を先に固定する。総数<=500000、各groupの期待件数をfailure documentで数値固定する。Okはto_bits、Errは厳密文字列、両分類を逐次照合。有限caseの網羅はf64全域証明ではなく、4nativeの代替でもない。

ln_count/ln_cts/newは全本文復元で不変を確認する。constructorの追加allocationは0。fixtureのnative exp wrapperを旧新各1つno_mangle/inline neverで用意し、生成asmを局所確認する。wrapper命令はこのfinite EXEだけの証拠であり通常codecの命令やCPU shareではない。

## 所有と実行

新root hard-cut-exp-scale/。同workerがFAILURE_PLAN.mdを先に保存してからscaled_math.rs/probe.rsを所有する。親PLAN/runner/readonly検証/RESULTは親所有。旧math/他source/report/EXE、phase1/2 profile証拠は凍結。workerは非書込構文/全文1site比較のみ、compile/native0で停止READYを返す。親レビュー後だけcompile1/native1。再測定・選別・重複起動なし。

sourceとplan<=64KiB、EXE<=1MiB/asm<=2MiB/report<=256KiB、新出力build/khc-hard-cut-exp-scale-20261004全体<=8MiB/空き5GiB。実データコピー0、生case/trace0。数学の小候補確認なので固定codecはまだ再実行しない。正常全frame/Proof/破損維持と非計測通常速度は次段で判定する。今回の有限成功だけで採用や7-Zip超えと呼ばない。

Modernizer依存変更なし、Normalizer式1site統一、Performance実命令差未確認、Hardening/Tester先行domain/bit契約、Cleaner追加表/生copyなし、Async Math所有寿命のみ確認。Intel/製品Startup非該当。Git/version/API/x86/外部/削除なし。元正式gateとGOAL activeを維持。
