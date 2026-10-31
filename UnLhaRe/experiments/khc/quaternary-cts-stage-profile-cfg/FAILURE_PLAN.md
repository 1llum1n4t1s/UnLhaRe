# cfg依存修正試行: コード前の失敗計画

親固定 `../QUATERNARY_CTS_STAGE_PROFILE_CFG_CONTRACT_20261003.md` に従う。前失敗source/reportを凍結し、前FAILURE_PLAN（21052B/SHA95E16CD00334D6297FEE7A764A267567C0AE27D8C81ED4C7F30E01781A0455EC）にあるexact recipeを継承する。本ファイル保存時は新codec/probe/runnerなし、新buildなし、今回compile/CLI0。

## 失敗を先に列挙

- 前compileのcfg不整合: frame_audit helperがprimitive_audit seed定義を必要とした。今回は両cfg、opaque helperの呼出追加0。再度compile失敗なら非zeroとstderr/予定1完了実数を保存し、候補CLIを開始しない。
- basis/169凍結参照/新5参照/parent_basisのSHA・bytes・UTCticks・alias・graph・token差。1件でも拒否。前試行のafter/liveは未完了、今回174全件before/after/liveを独立に照合。
- 無効component/prefix/mode、counter/elapsed/child sum overflow、ticket/順序/重複/unfinished scope、負残差、sample/branch数不整合。合計45期待Err。syntheticは全state before/after Eq、時計なし。
- E2E先行操作の失敗は現在fixture/ordinal/seed recipeと実Errを記録し、前caseのOkを再利用しない。ケース完了前は0、途中操作は実完了だけ。83case以外を加えない。
- 同body disabled modeが変化、全frame/plain/Proof14/all stats/旧固定値の差、方向の層counter差、bucket/top/clock数不足、candidate所有数逸脱。first field/indexとbounded evidenceを保存。
- timeout/panic/nonzero/JSON不正/過大出力/CIM失敗/write/sync失敗。回収不能な内部完了をnullとし、census不可はunknown、query成功で残存ならその情報を保持。censusと保存を独立try。failure保存の注入は本試行で追加せず未検証。
- 空き不足/reparse祖先/新root既存/source300KiB/EXE1MiB/JSON256KiB/保持1.25MiB/fresh8MiB超過。各write前gate、CLI開始前gate、serialized report直前gate。root外削除/入力コピー/共有cache/Cargo/PDB/asm/raw traceなし。

## 固定loop・group・case

| group | exact cases |
| --- | ---: |
| GOLDEN | 9 |
| STREAM | 8 |
| STREAM_SCOPE | 16 |
| TOP | 1 |
| ESCAPE | 1 |
| BAD_COMPONENT | 8 |
| BAD_PREFIX | 6 |
| MODE_OK | 2 |
| MODE_BAD | 3 |
| DISABLED | 1 |
| OVERFLOW | 14 |
| LIFECYCLE | 10 |
| RESIDUAL | 4 |

12loop/13group/83case、Ok38/期待Err45。STREAM_SCOPEはSTREAMと同loop。境界n=0,1,127,128,129,383,384,385,u64MAX→0,0,0,1,1,1,2,2,72057594037927936。2component×4prefix×385枝=3080、層ordinal128/384だけsample16、4scope/pair×16=64/128endpoints、parent100ns/children10/20/30、各残差40ns/総640ns。top100/200/20/30,total350→残差50/top pair4。escape7で他state不変。disabled385枝/escape7/top4で全initial state不変。

overflow14/ lifecycle10/ residual4/無効component8/prefix6/mode3のexact seed・expected Errは凍結前計画の値を使う。故意のMAX seedをAPI到達可能としない。全拒否before/afterの全field/Bucket/branchを比較し、digest代替なし。

## 新sourceとgraph・実行量

所有4ファイル、親一人。codec/probeを凍結前sourceと同byteでコピー。runnerのみ新root/前失敗basis schema/174 identities/追加primitive_audit/parent_basisに接続する。数値/wire/state/timerの26allowlistは不変。graph10 unique/9edgeと全old参照は前graphと同じで、所有codec pathだけ新rootへ移る。root aliases reference_cts→integer_cts、codec baseline_cts→integer_ctsは不変。

nonExecuteは出力なし・compile0/CLI0。今回compile1/CLI profile INPUT1/encode2decode1/inputread1/空Instant10000組1回。前失敗を含め予定累計compile2/CLI1。全frame478750B/plain2811006B/Proof14×2/stats3、枝各方向3825340/escape742、8層予定sample式、transform/payload/model_new/finish_audit各1、開始終了pair/attempts/commitを検査。参照frame最大2枚957500B/最後参照0。追加測定0。

174 identities、前失敗basis56374B/SHA0D2DEDC2A4937361FE77C3F5C6C6EBE7ED38597C14653458E77478F36057563F、Q21 parent_basis別pin。JSONの事前projection262144B、native stdout前と同15429B以下/limit16384B、実serialized gateも維持。各child120s/total300s、所有process回収、実census結果を保存。新source≤300KiB、EXE≤1MiB/report≤256KiB/保持≤1.25MiB/fresh8MiB/free5GiB+8MiB、想定source約100KiB/EXE1MiB以内/report256KiB以内、時間180秒以内。heap/failure保存注入・formal性能・CPU・holdout・4native・製品APIは未検証。
