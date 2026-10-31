# CTS sealed snapshot: 結果と次の比較基点

## 結果・採否

非公開研究の通常observeから重複predictを除き、同一プロセスABBAで全入力encode平均 **9640.38115→7231.3023ms（24.9894564594%短縮）**。4回の圧縮frame474730B、候補decodeのplain2811006Bをそれぞれ既存frame/元入力とRAM上で全byte直接比較して一致した。固定CDF、grammar/base-pool digest、CRC、class観測数も全runで一致。研究の次比較基点としてsealedを採用する。

これは正式benchmarkではない。7-Zip総合超過、正式574.5624ms未満/機械CPU15%以下、holdout/categories、4環境native、製品/API統合は未達・未検証。製品通常default/API/wire/versionは変更していない。前段の19.7%と今回25.0%を足す/掛ける、別binary/時点の値から総改善率を作ることはしない。

全入力encodeはなお約7.2秒であり、固定正式条件との差は大きい。次は単なる整数算術micro改善を際限なく重ねず、CTS深さ/モデル計算段数の候補を、実frameの固定size gate・完全復元・安全性を保って比較する。固定条件を緩めたり、診断の平均で正式中央値を代用したりしない。

## 変更前後と同値性

旧KT64は各branchのpredict後、observe内で9KT+8mixtureを再計算しRawSnapshot全体の一致を確認する。新方式はprivate `visible` とprivate `certified` の2つのRawSnapshotを持つsealed型をpure predictで生成する。Deref/DerefMutはvisibleだけ。現在の全causal stateとvisible、visibleとcertifiedが一致する通常経路ではderived計算を省く。

拒否順はprefix→class/child→token/current CAP→全9node gather→leaf→level昇順weight/raw CAP→causal比較→seal比較を維持。causal一致だがvisible!=certifiedなら、旧predictとのRawSnapshot全体比較へフォールバックする。初期snapshot.classを同stateの別classへ変える場合など、旧が受理する合法改変を無条件拒否しない。新tokenのcertifiedまで含むEqを旧RawSnapshot比較の代用にしていない。

private constructorは成功predictのみ。certified公開/Default/from-raw/Deserialize/unsafe/cache/nonce/owner IDを追加しない。予測は&selfのまま、後段pool失敗もCTSを変更しない。別Ctsの同じ数値state由来snapshotを受理し、update_kernel・全9prepared node・commit順とKT/mixture式は凍結した。

derived省略の根拠: prefix1..4、全4raw和<=CAP、各weight<=Q、leaf=Q/2では、KT active denominator<=7650684<Q、mass×Q<=32859424687128576<2^55、最小KT quotient>=561。Q-normalized正vectorの凸結合はmass総和Q²で、u128の範囲内、Hamilton後も正のQ-normalized vectorとなる。したがって旧predict_kernelのderived追加errorは合法causal stateから発生しない。現在stateの入力guardは省略しない。

Snapshotのsizeofは1488→2976B、CTS node storageは旧新とも12582864B。追加1488B/tokenのコピー負担込みで今回ABBAは改善した。全体peak RAMは未計測なので省メモリとは主張しない。この型は非公開研究用で、旧RawSnapshot aliasとのRust source互換性はない。公開製品APIの変更ではない。

model/newwireは凍結KT64 numericalbodyと同じ（末尾空行の整理のみ）。oldwireは同じbodyのstatic CTS alias変更と未使用selfcheck入口の除去のみ。rootにruntime CTS enum/dyn dispatch、内側timerを追加していない。

## standalone E2E（コード前の失敗計画）

`compare-snapshot` は成功392、拒否223、failed predict22を固定seed1831565813で実行した。成功ごとに全nodes/history/observationsを旧新直接比較392回。各拒否のexact reasonと、旧/新それぞれbefore/after全state無変更を446回、failed predict無変更44回確認した。digest `4ed027cbcaf271d4` は直接比較後の補助で、hashだけによる検証ではない。

| 範囲 | 実測件数 |
| --- | ---: |
| 合法sequence / lifecycle / 合法modified / 準備 / CAP exact | 384 / 3 / 3 / 1 / 1 |
| visible tamper / stale / class CAP / node CAP | 167 / 1 / 1 / 9 |
| invalid current / dual invalid / early guard / current priority | 18 / 18 / 6 / 3 |
| failed predict | 22 |

exact reason件数はstale166、invalid prefix2、invalid observation3、class update cap4、node update cap9、invalid leaf3、kernel weight17、raw observation cap19。kt/mixed/masses各全36要素、depth、全raw/weight/ids、history/obs/class/prefixを含む。合法class redirect、prefix/derived交換、古いsealのvisible一式を現在predictへ交換するケースも受理一致した。leaf対root raw、root weight対root raw、早いraw対遅いweightのdual-invalid優先順を実確認した。

独立selfcheckは凍結normal14/plain14/canonical14、malformed30 exact reason、model named14/assertions16、CAP exact1、CRC fixtureを実行しpassed。full profileのcanonical再encodeは実行していない（normal14のcanonicalとは別）。after-code unit testは追加していない。

## 実行台帳と計時境界

事前PowerShell/Rust構文確認と親nonExecute成功後、Execute一回・compile一回・3CLI各一回。UTC `2026-10-03T00:20:52.1852225Z`→`00:21:42.9104911Z`。Windows11 Pro10.0.26300/x64、Ryzen5 7640HS（6core/12logical）、PowerShell7.6.5、rustc1.98.1をpin検証。

コンパイラ: `C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe`、SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。PowerShell runtime SHA `362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139`。source cwd `C:/Users/IMT/dev/UnLhaRe/UnLhaRe`、親preflight cwdはその親。

compileはedition2024/frame_audit/primitive_audit/opt2/overflow-checks=yes/panic=abort/debuginfo0/DEBUG:NONE、3235.0566ms、exit0。旧/new reexportのnormalize/posterior_switch unused-import warnings2件のみ。候補3CLIはstderr空・exit0。compare2306.3348ms、selfcheck1124.3215ms、profile40367.69ms（これらはlaunch/drain込みの診断wall）。profile child TotalProcessorTime40000msは機械CPU15%の証明ではない。

| index | variant | encode callのみ ms |
| --- | --- | ---: |
| 0 | KT64 | 9733.5047 |
| 1 | sealed | 7031.2337 |
| 2 | sealed | 7431.3709 |
| 3 | KT64 | 9547.2576 |

sealed decode call6548.315ms。encode/decodeの内部clockはcall前からreturn直後、stats formatting・frame/plain比較・JSON・dropを除外。warmup0、追加repeat0、内側timer0。コード配置、CPU scheduling、clock overheadの診断制約がある。前段KT64平均10.1126sと今回KT64平均9.6404sは別binary/時点であり、その差は今回候補の効果に含めない。

全run固定stats: frame/header/payload474730/281/474449、plain/payload/header CRC433441561/3589341169/1741345118、runs889227、primary1762795、alphabet257、rank/length各889227、escape742、branches2725772/1099568、grammar58735a2b7383d755、base-pool9128444225deabce、classes[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990（許容1e-4）。fixed size474730<=483599の既存達成を維持しただけで総合達成ではない。

## 証拠・容量・再開条件

事前契約SHA `622867411E6A90CDD491D3EF96DA7640D20F47015B2AF29FCCF4521DFB6F0B9D`。出力 `build/khc-quaternary-cts-sealed-20261003/` は2件のみ:

| artifact | bytes | SHA256 |
| --- | ---: | --- |
| report.json | 139246 | B2EA272A74F5484993A2DA0A6396CC620A6BD6EA697868AB5DA99B24BE24237B |
| profile-o2-yes.exe | 374784 | FF3EA779B4A28A4EBE06465430B6F8747F7CE5475C4B76623199FA1E89E016F2 |

合計514030B（約502.0KiB）、8MiB guard内。予約EXE1MiB+report512KiB=1572864Bを生成前に確認。最終空き約86.45GiB。source72前後/親live、旧KT64 closure60、旧basis48、EXE前後のSHA/bytes/UTCmtimeすべて一致。graph14 unique source/14 edges（root11、wire→model2、newwire→e2e1）。owned codec process0、明示temp0、input/frame/restore disk copy0、Cargo cache新設0。guardは前後確認でOS quotaではない。cleanup-incremental dryrunはtarget0/bytes0/appliedfalse、削除なし。共有cache/x86/既存固定証拠は保持。

| 新source | bytes | SHA256 |
| --- | ---: | --- |
| comparison.rs | 12003 | 72E4991A8DB612AFC5D11384665FC340ADDF6E55C133A6CFB38B657BC5A1ED60 |
| FAILURE_PLAN.md | 6327 | 056FD496B2AD260A29300829C097C52D2408A930B743C61AF514A6FC62BDCC9E |
| integer_cts.rs | 9410 | E953BBA82FE27C64C1588EE1E6D3A4C33E64E1DB28BB3E75A25ADF506601E496 |
| model.rs | 11735 | 4A59EDF0545EC2D5E57CEC55396453A14E784D152A50BA0F38A7F4A7904D5FCA |
| new_wire.rs | 18818 | E364C2F94AF4DE4C576635172A057C8D71FF0867F18B1A59EE2359BEDC4F7B60 |
| old_wire.rs | 18699 | ABF3B0622BDC3402ABF1BAA4A429904648553582662DA4D48FFA08909E8AA781 |
| profile.rs | 7472 | 5B4466544B07A38D30F9D1959C69038CF2157C4619CB36FB9BED5E997623560F |
| verify-sealed.ps1 | 36521 | 1C59D55BCE88D9EFD77A15A2DD6CC57E6649BE80011EA33A15E0254BE90AC816 |

runnerは既存出力rootへの上書き/再試行を拒否する。保存EXEの3CLI、固定入力/frameパス、compile argv、全source/compiler/runtimeの識別値とstdout JSONはreportに残る。新しい計測は既存証拠を消さず別契約/新rootで行う。生成物の再現可能性はこの固定source/設定/入力/失敗計画で追跡できる。

## opop台帳・残作業

| ID | 結論 | 証拠 |
| --- | --- | --- |
| Modernizer | 現状が最適 | toolchain/依存固定、更新不要 |
| Normalizer | 改善を採用（研究） | sealed通常経路と旧exact fallbackを分離 |
| Performance | 改善を採用（研究） | 同binary ABBA全encode約25%短縮 |
| Cleaner | 現状が最適 | 旧証拠baselineとして保持、出力2件のみ |
| Hardening | 改善を採用 | 数値式/guard順/合法改変受理/拒否無変更を維持して高速化 |
| Tester | 改善を採用 | prewritten失敗計画、392/223/22 direct stateとnormal/full E2E |
| Async | 現状が最適 | pure &self、cacheなし、RAM drop、child finally解放 |
| Startup | 現状が最適（今回scope） | node storage不変、追加tokenコピーの負担を含め比較 |
| Intel | 非該当 | 外部現在値の判断不要、ローカル凍結数値/状態契約で決着 |

親は全新source/旧新差分/runnerを確認。別文脈のanalystは指定旧4ファイルと事前契約から、derived省略/guard順/純粋性/合法改変を反証し成立反例なしを返した（候補実行の独立検証ではない）。実装worker-high要求gpt-6.1-sol/high、監査analyst要求gpt-6.1-sol/medium、tool role固定設定のままで手動overrideなし。hidden server設定の独立実測とは区別する。

最終 `git diff --check` はexit0（既存DESIGN.md LF/CRLF warningのみ）。製品全build/test/4nativeは今回未実行。stage/commit/push/version/公開なし。goalは未達・active、本段階はprogress。
