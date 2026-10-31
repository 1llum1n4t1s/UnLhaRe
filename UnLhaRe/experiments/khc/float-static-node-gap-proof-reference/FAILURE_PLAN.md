# exact Proof参照訂正：先行失敗契約

親訂正note FLOAT_STATIC_GAP_PROOF_REFERENCE_CORRECTION_20261004.md SHA 77DAF888ABC03C834FA8DC14E6454FA4C5F09891D0616CEB92037ED63FCF3FA8 を全文読了。

初回report SHA E6C92D06FA9F35C26DACDD1F7AC210E4C3CAAA61C914421C40D858EF7DEAE090 は compile1/native1 で複合終端条件に失敗し、actual値未保存。旧statsの {:.9} をexact f64 bitsへ変換した参照値6010は不適切だった。旧Rust21source、旧runner、旧FAILURE_PLAN、失敗report/EXEは一切変更しない。

訂正はrunnerだけ。既存FT1成功report SHA D21A852CCDE81624DBB3138838E722A1CF547E33AC0419B81CB618B884BD0507 の固定case、typed Proof14全比較済み整数 cdf_bits=4705459439931356009 を取得する。丸め表示とのNear比較は1e-6のまま、native内部exact bit比較は一切緩めない。

実行前に拒否する失敗：親訂正note/旧失敗/FT1report SHA不一致、FT1 status/case重複・欠落・Proof14 field数/値不一致、固定入力identity不一致、原参照sources前後/live不一致、初回21sources/20edges/87991Bのidentity差、旧runner/failureplan差、sourceroot誤接続、新output既使用、PS構文/全文allowlist残差、資源/容量超過。実行後は原契約の全Meta/CDF/digest/entropybit/staticQ/component/class/node総和を同じ厳密さで検査し、失敗は保存して追加再試行しない。

新output build/khc-float-static-node-gap-proof-reference-20261004 はEXE/reportだけ。新runner自身/本書/訂正note/旧失敗report/旧runner/旧FAILURE_PLAN/FT1reportと参照source/tool/input/planをbefore/after/live pinする。追加single compile/nativeは親だけが実行する。workerはAST/graph等の非実行確認だけ。研究全体は初回compile1/native1を保持し、訂正後合計上限compile2/native2。

変更しない上限：compile60秒/native120秒、source300KiB、EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、各生成root8MiB/free5GiB、モデル32MiB/phase64MiB/WSとprivate commit各160MiB。係数/設定/分布/数値/fixtures/計時/資源寿命は変更しない。モデル保存/codec/frame/速度/因果寄与/holdout/portable wire/採用の主張なし。総合goal未達/activeを維持。
