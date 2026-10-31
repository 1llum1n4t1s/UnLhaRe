# CTS alpha共通係数: 生成コード診断結果

## 結論

凍結旧primitiveを直接参照する独立libraryの生成bodyでは、after+1加算はloop外へ移る一方、alphaの除算とretained算出は成功経路の各更新段に残っている。PERF-ALPHAを小さな単独候補として試す根拠は得られた。ただし既存full binaryの最終inlining/配置と同一とは限らず、速度効果や全入力での命令削減を実測した意味ではない。基点depth5旧pool/旧Mathは維持する。

## 実行・証拠

計画 `QUATERNARY_CTS_ALPHA_CODEGEN_PLAN_20261003.md` の失敗条件をharness/runnerより先に親が保存した。親のみが計画/probe/runnerを編集し、PS parser/nonExecuteで136 identities前後一致・output未作成を確認した。その後rustc --emit=asmを1回、225.5617ms、exit0、stdout/stderrとも空で実行。benchmark/候補CLI/旧EXE実行は0。

| 保持証拠 | bytes | SHA256 |
| --- | ---: | --- |
| build/khc-quaternary-cts-alpha-codegen-20261003/baseline.s | 7903 | 995D724CF94F20E8A559365A5824BAA630DB5F15346207BF80E950D4AA66F12E |
| 同root/report.json | 68766 | 8567E1E1848E04609A482BA954DC757DF97A44857800BA71A6A0F778755DCE09 |

compiler rustc1.98.1 SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、edition2024、opt-level2、overflow-checks=yes、panic=abort、debuginfo0、frame_audit/primitive_audit、x64 Windows。root wrapper2件は旧functionへの直接callだけで、旧source q32のSHA5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7は変更していない。

## bodyを読んだ根拠

- baseline.s:43はafterをr14dへload、:74のincl r14dはafter+1。loop入口.LBB0_6は:80、戻り辺は:146のjne .LBB0_6で、加算は外側。
- :124-126はQを被除数としてdivq r14を行い、:127は商alphaを保持、:128-130でQ-2*alphaを算出。これらは戻り辺の内側で、depth5正常完了なら5回実行する。
- :116のcallq __udivti3はposteriorのnumerator/rawmass用で、alpha除算とは別。PERF-ALPHAではこのu128除算を削減しない。
- :64-65でdepth0は.LBB0_15へ分岐し、係数計算を通らず成功する。候補も空loopの意味を維持する必要がある。

親が全370行を読み、readonly analyst cts_alpha_audit（gpt-6.1-sol/medium）が親の解釈を渡されずに同じbodyと境界を確認した。div件数の文字検索だけで判断していない。候補側の生成コードやfull binaryのコード生成はまだ確認していない。

## identity・容量・次工程

凍結Math report130のbefore/after/liveと、新6件の計136identityが一致。親の別live SHA/bytes/UTCticks照合もmismatch0。生成物はassembly/reportの2件76669B（約74.87KiB）、1MiB予算/assembly512KiB/report256KiBに収まる。終了時空き80755994624B（約75.21GiB）。binary/rlib/object/PDB/input/frame/plain/trace、用途済み一時物は生成していない。所有child終了、live codec process0を確認した。小さなassemblyは再現証拠として保持し、削除対象なし。

次工程は新private alpha_kernelでだけ共通化し、凍結q32を旧oracleとして残す。現mid比較はold/newともreference_cts::update_kernelを共有するので、共有旧sourceを上書きして一致を主張してはならない。depth0、after境界、複合不正/段順優先、拒否後全stateを新E2Eで加え、旧selfcheck/全frame/Proof/statsも維持する。性能は事前固定の同一binary ABBA1周で両方向短縮かを判定する。

opopでは改善採用ではなく、Performance/Hardening/Testerの根拠確認を採用した。formal median<574.5624ms、CPU<=15%、holdout/categories、4native、製品/API統合、7-Zip総合超えは未検証・未達のまま、goalはactive。
