# 全CTS混合を1乗算へ — 実装前failure-first契約

研究基準はexact-div（log-table/floatは静穏full比較未完了）。equality-probeは36 checks/61 CLIと24成功JSON/8fixturesのcounter検証を通過。固定7622618 bitsでは121961888 mixture/posterior呼び出しの等値4509629（3.6976%）、retained-half4406596（3.6131%）、KT fresh727109/129584506（0.5611%）。3つの恒等式は独立数学照合済みだが、等値shortcutのみのbranchは頻度が小さく、速度未測定のまま優先しない。今回はすべてのmixtureで2乗算＋積和を1符号付き乗算へ減らす。これも速度改善は未証明。

## 恒等式と検査範囲

Q=2^48。検査済みw in[0,Q]、kt/child in[1,Q−1]で、元式は

`floor((w*kt + (Q-w)*child)/Q)`。

`child + floor(w*(kt-child)/Q)` と厳密同値である。w/kt/childはi64に収まり、delta=(kt as i64)-(child as i64)は(-Q,Q)。signed productをi128で計算して `>>48` する。負数の商を0方向へ丸める `/Q` に変更してはいけない。w=1/kt=1/child=2は結果1（0方向丸めだと2になり不正）。i128積の絶対値<2^96、補正とchild加算も安全、結果は1..Q−1。旧checked u128積・和のoverflowは、この検査済み域では到達不能なので、その計算を省略しても成功/失敗は変わらない。weight検査→kt probability→child probabilityの順を最初に保持し、最後もu64変換/probability検査を残す。

近似/floating arithmetic/FMA/確率丸め/モデル/深さ/context/prior/更新順/wire変更なし。等値特殊branchや他の改善と組み合わせない。KT/posterior/retained/exact-div/BWT/Bayes/range/CRCは凍結のまま。符号付きshiftの数学と実結果は独立BigIntegerの正の元式および小さい負delta境界で検証する。

## 所有・配線

新causal-bayes-signed-mixture/{codec.rs,cts_model.rs,audit_cli.rs}とbuild/khc-bwt-causal-bayes-signed-mixture-20260930/だけを所有する。codecはexact-div copyからCTSの新module/凍結exact_div相対参照だけ。CTSは元mixture本体だけ差し替え、cfg khc_mixture_audit専用の実mixture呼出wrapperを追加。診断counterはコピーせず元Node/Tree/Prediction/Modelを維持。製品/凍結研究source/proof変更なし。Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定、auditのみopt2も生成。

## 先に列挙する失敗と数値CLI

negative deltaを0方向丸め、u64 subtraction wrap/invalid cast、符号拡張/shift違い、weight=0/Q・kt=child・1/Q−1境界不一致、旧error precedenceの変化、確率0/Q/weight>Q許容、Model/node/history/観測順/CTS他式/source範囲変更、cfg診断の通常hot path流入、巨大input/不正record/argc/no-clobber/I/O失敗時自身以外の削除、source/proof途中変更、既存work上書きを拒否する。

audit inputは24byte/record(w,kt,childのu64LE)、最大65536 records(1572864bytes)、empty許可。全length/regular/bounds検査後、実mixtureを呼ぶ。outputは16bytes/record(status u64LE,value u64LE)。status0=成功、1=weight範囲違反、2=Q48確率範囲違反、拒否valueは0。これ以外のerrorは監査CLI自体を失敗させる。w/kt/childの不正recordも数値error分類の検証対象なのでinput syntax errorとは区別する。全計算終了後create_new/write/sync、成功JSON operation='cts-mixture-audit',cases=count。new unitなし。

新auditのwrite/sync失敗はerrorを返してhandleを閉じ、pathによる削除を行わない。外部の同時path置換を自身のファイルと誤認して削除しないためで、I/O故障時に部分own outputが残り得ることを限界として報告する。syntax/数値計算失敗はcreate_new前なので未公開、既存outputはno-clobberを維持。凍結fullcodecの旧path-cleanupはこの数学変更では触れず、その既存万能保証なしと区別する。任意I/O故障下の残存なしは完了条件として満たしたと称さない。

独立PowerShell BigIntegerで元の正の積和を計算し、全u64 edge/各2冪/負delta最小差/固定seed valid乱数/invalid precedence/最大65536境界を照合。opt3/opt2各別process2回の全output bytes一致。MAX+1/24byte非整列/argc/不正regular入力/no-clobber、未公開を実CLI E2Eで確認する。OOM/I/O故障注入は未実施なら区別する。

全codecは凍結old opt2との36 checks/61 CLIを継承、fixed483468 bytes/SHA B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A、CRC修復負例/既存出力保持/11metadata・本文・EOFを確認。別独立read-only担当がsource許可diff/代数・境界/BigInteger raw出力/実exit/全frame/proofを照合する。全証拠後にのみcandidate/frozen exact-div/native7zの39CLI/warmup1+9/循環順/静穏guard付き全CLI測定で採否判断する。

固定group2811006bytes/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、全archive<=483599bytes、strict encode<574.5624ms、thread設定/nativeoptsを維持する。1乗算化を速度向上率や7-Zip超過の代用にしない。holdout/複数カテゴリ/portable native/製品統合は別、Git stage/commit/push/version/deps/公開なし。初回最終・最終proofは保持し、不要反復だけ安全条件を確認して清掃。旧policy拒否/cache/UnLha32Re/registryへ操作しない。
