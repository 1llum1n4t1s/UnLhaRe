# CTS KT同値u64専用化・固定ABBA結果

## 結論・採否

progress。KTのHamilton正規化をchecked u64へ専用化し、4128合法全4値＋10320childの商/余りが凍結u128と直接一致。8拒否exact理由とscalar3groupもpassed。局所5paired中央値2513600ns→1317000ns、47.6050%短縮。固定pow2/kt64/kt64/pow2の同process encode両候補回は両基点回より短く、平均12596.90545ms→10112.64525ms、19.7212%短縮。H1/H2は今回の診断で支持。

全4frame各474730BをRAMで凍結baselineへ全byte比較して一致し、候補decodeで全2811006byteの復元も一致。frozen standalone E2E normal14/canonical14/malformed30/model assertions16/CAP exact1 passed。Snapshot全再predict比較、件数上限、prepared後commit、一般normalize/pool、数値意味を維持した。

採用は研究候補の同値KT専用化まで。次の比較基点としてkt64を使えるが、製品通常default/API/wire/versionへの統合採用は保留。診断値は正式中央値/CPU15%/7-Zip総合達成ではない。前段の計測付きpow2平均10.3587sと今回の無内側timer pow2平均12.5969sは別binary/時点/配置なので相互比較しない。12.2%と19.7%を足したり掛けたりして総改善率を主張しない。

全体はまだ約10.1秒。正式574.5624msとは計時境界も異なるが、秒単位の差が残るため、算術micro改善だけを際限なく続ける方針にはしない。次は計算段数を減らすモデル構造候補も、固定size/完全復元/安全契約を維持して調査する。全goalは未達・active。

## 変更・数値根拠

新 `quaternary-cts-kt64/integer_cts.rs` は凍結pow2 moduleをコピーしkt reexportだけを専用関数へ置換。prefix検査→全4raw checked和→CAP拒否は旧と同じ順/理由。active prefixだけのmass=2*raw+1、D=sum(mass)、product=mass*Q、floor商/余り、余り降順＋child昇順tie、left配分、vector確認は同じ。

CAP3825340/Q2^32からmaxmass7650681、maxD7650684、maxproduct32859424687128576<2^55。合法旧入力はu64に正確に収まり、狭幅checked追加guardで新たに失敗しない。最大値は比較入力でも実観測。prefix外rawはDへ入れずCAP全4和へは入れる。generic normalize/pool公開/拒否意味はreference aliasで不変。

親の独立BigInt4128入力確認でも同じ最大値、非zero-left tie13件、uniform3 remainder[1,1,1]/left1→[1431655766,1431655765,1431655765,0]を確認。これはRust実行証拠とは別の数学確認。直接比較をdigestだけで代替していない。

共通新modelは凍結BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9のcrate→super2箇所のみ。両wireの数値本体は凍結codec673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327と同じ。具体Cts aliasは基点pow2/候補kt64。root一般helperはreference。hot runtime enum/virtual dispatch/内側phase samplerなし。新wireだけに凍結e2eとdecode wrapperを接続し、旧CLI main/importを研究rootへ置換した。旧sourceは編集していない。

## 固定実行・環境

- 契約SHA256 `12C7F578C902D58CEF8438022513DFA63F5A587410C1BB55AD8FDDEC83E87167`。実装前FAILURE_PLAN保存、親がplan/Rust6source全文と旧との差分/runner全文を確認した後、編集停止を回収して一度Execute。
- 実装は既存worker-high、要求/継承gpt-6.1-sol/high、新規起動なし。モデル実効値を外部観測したものではない。親が6基本観点＋Async/Startupを調査・採否・統合・実行。
- 親最終nonExecute passed、source60前後/旧phase48basis/14unique source14edge/静的alias/peak1572864B一致。root未作成0B。graphはroot11edge＋common model2＋candidate wire→frozen e2e1。
- bundled pwsh7.6.5 `C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe` SHA `362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139`。
- rustc1.98.1 `C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe` SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`、version `rustc 1.98.1 (48a229cea 2026-09-01)`。
- Windows x64/Ryzen5 7640HS/6core12logical。CPU/OS/compiler/runtime/CWD/source path/hash/bytes/mtimeは計測前にreport保存。
- compile1回、edition2024/frame_audit/primitive_audit/opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE、2505.6483ms/exit0。旧pow2と新KT64のnormalize/posterior_switch reexport unused warning2件。検証CLI stderrはすべて空。凍結証拠をwarning解消目的で変更しない。
- UTC 2026-10-02T04:18:47.2738787Z～04:19:49.5241659Z。compare110.8819ms、selfcheck1129.3633ms、profile55073.7881ms、各exit0/各120秒以内。
- 3候補CLIを各1回、profileは4encode＋1decodeのみ、warmup0/追加repeat0/未知失敗retry0。旧Executeは再実行なし。
- profile child TotalProcessorTime53921.875msは診断。machine CPU15%の測定・達成証拠ではない。code placement/clock/CPU schedulingを未分離。

## compare-ktとselfcheck

4128=32境界（prefix4種×raw8種）＋seed0x6d2b79f5の4096LCG。8exact拒否、scalar3group、10320child商余りを逐次比較。prefix外CAP/forced/uniform3 nonzero remainder tieも直接照合。全大きな積はchecked u64境界を確認。

局所5paired×16pass、calls66048/round side、330240/side、order old-new/new-old/old-new/new-old/old-new。

| round | old ns | kt64 ns |
|---|---:|---:|
| 0 | 2893700 | 1485700 |
| 1 | 2439300 | 1244400 |
| 2 | 2513600 | 1317000 |
| 3 | 2543500 | 1254300 |
| 4 | 2408100 | 1437000 |

median2513600/1317000ns。全10digestのexact整数4256164640105587397、各count66048一致。JS doubleの丸め値をdigest同値判定には使っていない。

frozen selfcheck normal14/全plain14/全frame canonical14、malformed30各exact理由、model named14/assertions16の全state拒否無変更性、CAP exact1、既知IEEE CRC fixture passed。heap/write/sync障害注入・一般8MiB入力保証は未検証。

## 全入力ABBA・復元E2E

input2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、baseline474730B SHA `9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD` を各一度bounded read。frameを一件ずつ全byte比較→drop、4run後候補decode1回→全plain比較→drop。disk入力/frame/restoreコピーなし。

| run | 方式 | encode ms | matched frame bytes |
|---|---|---:|---:|
| 0 | pow2 | 12850.6707 | 474730 |
| 1 | kt64 | 10149.8296 | 474730 |
| 2 | kt64 | 10075.4609 | 474730 |
| 3 | pow2 | 12343.1402 | 474730 |

candidate decode9576.3846ms、matched plain2811006B。平均は診断整理だけで正式gateではない。各encodeの計時はencode呼出直前→戻り直後で、stats formatting/全frame比較/JSON/dropを除外。全入力canonical再encodeは追加せず、4frame一致＋normal14 canonicalと区別する。

全encode4とdecode1の固定stats: frame/header/payload474730/281/474449、CRCplain433441561/payload3589341169/header1741345118、runs889227/primary1762795/alphabet257、rank/length各889227/escape742、枝2725772/1099568、grammar58735a2b7383d755/base-pool9128444225deabce、classes[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990±1e-4一致。digestはbase count/pool値だけで全CTS state digestではない。

全run progress flush、restore progress/final/raw/parsedをvalidators前保存、byte comparison frame4/plain1も保存。local_probe_validated/selfcheck_validated/profile_validatedすべてtrue、statuspassed。数値正確性と速度未改善を区別するrunnerで、今回は両方改善。途中失敗/timeout時はpartial保存/no retryであるが、その失敗経路の障害注入は今回行っていない。

## 容量・保持・識別値

fresh root `UnLhaRe/build/khc-quaternary-cts-kt64-20261002/`、8MiB予算、事前0B、scalar peak予約1572864B、見積1.25MiB以下。保持はEXE/report2件、472109B（約461.0KiB）。新しい明示的な一時fixture、Cargo/PDB/cache/asm/rawtrace/table、disk input/frame/restoreコピーなし。

| 証拠 | bytes | SHA256 |
|---|---:|---|
| profile-o2-yes.exe | 359936 | 2B22BC6C5BFB39D9307D86D722A185632B61CD4F28D9098F9FFABBCAF6A57040 |
| report.json | 112173 | C88FBE8B6FD30B68D013329C3A34D7BEA09A456129F5D06DBF9AF1A72959398B |

新8source:

| file | bytes | SHA256 |
|---|---:|---|
| integer_cts.rs | 7495 | 90533959E33165C93752D67F0A6B7E8C925F10A9E6AFEE1E03D60F4F25E7D52B |
| model.rs | 11738 | 5A69F5A19035A18489D59DF82FD2DBFB423817CCF16414888F2C45BE35271889 |
| old_wire.rs | 18339 | 5DD0E25F0FDE6179F209E8245A73C0817ABBFEFC1B490121BB94E76D2BAAC5A8 |
| new_wire.rs | 18819 | C49EA2593C42A0899E9A50D7E8F59365163F014D4F6CBEE772559385DCC77838 |
| profile.rs | 7450 | 4A3ED806210CA5E617CE21FB131B8B81A4FF8208FE8FA0B161F10E5251C9C81B |
| comparison.rs | 5970 | C3A9CD3F95A9D4E64960C13740D0AB7B37304C6A390B440FB045F16F32DA6267 |
| verify-kt64.ps1 | 32050 | D8EF93A95585B1F7264830B3C4C62CEB9F14B8DAC26ED9EBCE47FBA0E52CA660 |
| FAILURE_PLAN.md | 4841 | 3BB1D03CC372DCA8E92C00CCB3AA7AE36D922340363FD67DFBB83C59A305F22B |

source60前後＋旧basis48のhash/bytes/mtime、EXE_before/after一致。旧phase report359A98…B0B7F/result697387…13A8/EXE FC938C…CD2Cも保持・不変。root links/混在なし、owned profile process0、残存明示temp0。容量guardは前後確認でOS強制quotaではない。削除なし。cleanup-incremental既定dryrunでもtarget0/bytes0/appliedfalse、依存/共有cache/x86/既存証拠に触れていない。

## 調査台帳・残作業

| opop観点/親担当 | 結論 | 根拠 |
|---|---|---|
| Modernizer | 現状が最適 | toolchain/依存を固定、更新不要 |
| Normalizer | 現状が最適 | genericとKT専用の責務/静的aliasを明示 |
| Performance | 改善を採用（研究） | 局所47.6%/同process全encode19.7%、製品採用保留 |
| Cleaner | 現状が最適 | 旧proof保持、2件・入力copy/明示tempなし |
| Hardening | 現状が最適 | CAP/prefix/tie/Snapshot/commitを保持し実拒否検証 |
| Tester | 改善を採用 | direct4128/10320商余り/8拒否/selfcheck/全frame4/全plain1 |
| Async | 現状が最適 | singlethread・一frame/stateずつdrop・child finally解放 |
| Startup | 現状が最適（今回優先順位） | 前段初期化約4ms、cache/tableを増やさない |
| Intel | 非該当 | 凍結ローカル算術で判断 |

最初のnonExecuteはpins追加の独立行commaがnested arrayに解釈され、verify-profile.ps1とSHAを繋いだ不正pathのFile.OpenでCould not find a part of the path。finallyのbasis再確認がこの先行例外を覆っていた。tuple末尾commaと初回basis成立後だけfinally再確認へ修正し、parser/nonExecuteを再確認。候補compile/CLIはこの修正後に一回だけ実行。親が修正差分と最終SHAを確認した。

次候補の数学メモ: reciprocalを同じKTのDで共有すればchildごとの商をhigh64(product*floor(2^64/D))＋最大1回補正で同値にできる（D1は別処理）。親RAM4128case/10320childでも直接一致、補正1042件。ただしRust実装/性能は未検証・未採用で今回sourceへ混ぜていない。固定全入力のKT68,856,120call/prefix加重和14,305,969×18=257,507,442商はsemantic formula countで、機械DIV回数ではない。算術候補の利益には上限があるため、モデル計算段数候補との優先度を次段で比較する。

正式574.5624ms/CPU15%/observer確認待ち/過去terminal protocolを変更・起動していない。holdout/categories/4native/製品API/汎用大容量対応も未検証。固定size474730≤483599は既存証拠を維持しただけで総合達成ではない。製品全build/testは未実行、Git stage/commit/push/version/公開なし。
