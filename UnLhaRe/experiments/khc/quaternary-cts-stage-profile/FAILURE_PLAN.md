# 旧Q32 depth5 stage診断: 実装前失敗計画（2026-10-03）

## 保存時点と権限

この計画は新codec/probe/runnerのコード作成前に固定する。今回の担当turnはこの1ファイルだけを作成して停止する。次の親followupまでは他の3ファイル、compile、CLI、Execute、benchmarkを作成・実行しない。旧source/result/report/EXE、既存dirty、共有cache、秘密、外部サービス、Gitを変更しない。追加委任しない。

正本契約 `../QUATERNARY_CTS_STAGE_PROFILE_CONTRACT_20261003.md` は8368B、SHA256 `067F5AF84A6EB4D3129C262242247B16AFC1B3C3861FA628B97143611C8E4871`。前結果 `../QUATERNARY_CTS_MIXED_Q21_ABBA_RESULT_20261003.md` は9202B、SHA256 `94FB800147EF15B2D11C75B33706499AD6276637BEE10A28FDE7F0610AAF3B62`。両方全文を読んだ。global、root、新版、experiments/khcのAGENTSとglobal agent-workflowを読んだ。コード後unit testは作らず、失敗を先に固定し、単一profile CLI内でstandalone契約E2Eを実行する。

## 問いと失敗分類

問いは固定開発入力でtransform/payload/top残差、および旧payloadのbranch predict/range/observeのどこに時間があるか。診断は改善率、採用、正式benchmark、製品完成の証明ではない。

| 分類 | 想定失敗と拒否点 |
| --- | --- |
| provenance | 契約/result/basis/source/input/runtime/compilerのSHA/bytes/UTCticks不一致、欠落、重複identity、case alias、読込中変更。compile/入力読込前に停止 |
| graph | 10source/9path edgeからの不足・余分、candidate/E2E残留、Q21/QCANCEL/Math-U64/Alpha接続、誤ったCTS alias、数値/timer変更。nonExecuteで停止 |
| invocation | 無効mode、argc、未知CLI、追加compile/CLI、input再読込、warmup/canonical/再実行。state/時計前に拒否 |
| sample | component/prefix範囲外、0-based ordinal、層の混合、抽出周期/位相ずれ、成功前に完了加算、missing/extra sample、escapeをsample。exact固定loopで検出 |
| counter | u64加算/elapsed変換/child合計overflow、開始終了不一致、duplicate/foreign/out-of-order scope、active scope残留、負残差。checked Err、丸め・wrap禁止 |
| codec | frame/plain/Proof14/statsの差、旧depth5固定値違い、非finite entropy、誤ったdepth/wire/CRC。最初の差を直接比較して停止 |
| lifecycle | decode/比較途中失敗、panic/nonzero/timeout、JSONなし・破損・unknown schema、plannedをcompletedとして記録。部分完了を保存しpassed禁止 |
| capacity | root既存/reparse、source/EXE/JSON/fresh予算、空き不足、予測書込超過、余分なPDB/asm/trace/frame/plain/inputコピー。書込前停止 |
| inference | inclusive二重加算、sample推計をexact扱い、overhead機械的控除、周期/cold/rescale偏りの無視。reportの意味を固定 |

heap/write/syncのfault injection、一般8MiB入力、holdout、4native、製品/API統合は含めない。失敗JSON保存のOS I/O失敗自体は起こり得るため、保存できなければ親へbounded stderrと保存失敗を返す。成功を推定しない。

## 最小ファイルと閉包

全pathの基点は `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/experiments/khc/`。新物はstage-profileのcodec.rs/probe.rs/verify-stages.ps1/このplanだけ、合計最大307200B。数値copyはcodecだけ。計画読込のdirect-source bodyはテンプレ1と以下の旧8、合計9を当初上限とし、別candidate bodyを読まない。下記のBWT是正に限り、親の明示許可でcorrective bodyを1件追加した。

| edge | importer → source（基点相対、将来compile graph） | alias |
| --- | --- | --- |
| 1 | quaternary-cts-stage-profile/probe.rs → quaternary-cts-stage-profile/codec.rs | codec |
| 2 | quaternary-cts-stage-profile/codec.rs → quaternary-cts-depth/model.rs | model |
| 3 | quaternary-cts-stage-profile/probe.rs → quaternary-cts-depth/integer_cts.rs | baseline_cts |
| 4 | quaternary-cts-stage-profile/probe.rs → quaternary-cts-q32/integer_cts.rs | reference_cts |
| 5 | quaternary-cts-stage-profile/probe.rs → quaternary-cts-integer-pool/integer_pool.rs | old_pool |
| 6 | quaternary-cts-stage-profile/probe.rs → quaternary-cts-integer-pool/fixed_math.rs | fixed_math |
| 7 | quaternary-cts-stage-profile/probe.rs → causal-bayes-sais/bwt.rs | bwt |
| 8 | quaternary-cts-stage-profile/probe.rs → rejected-binary-mix/packed_alphabet.rs | packed_alphabet |
| 9 | quaternary-cts-stage-profile/probe.rs → direct-token/multi_range.rs | multi_range |

rootを含むunique source10、明示path edge9。root `integer_cts` aliasはreference_ctsで旧pool用、codecのinteger_cts aliasはbaseline_ctsで旧depth/model用。depth CTSはcrate::reference_ctsを参照し、poolはcrate::integer_ctsを参照する。このuse alias参照は追加path edgeではない。packed_alphabetのsuper::Resultはroot Resultで解決する。

保存順の補足: 初版19916B/SHA256 `C571B2AA2FBDE1574E2BA8BEFFBA4A170A81ABE3DAE70FC80125589660B6F907` ではedge7をcausal-bayes-fast-bwt/bwt.rsと誤記し、そのbodyの冒頭を読み取った。親の全文確認によりQ21旧基点rootのprobe.rs:12は `#[path="../causal-bayes-sais/bwt.rs"] mod bwt` と指摘された。コード前のPlan-only followupでedge7を是正し、許可されたcorrective参照 `causal-bayes-sais/bwt.rs` だけを追加全文読込した。是正bodyは8528B/SHA256 `810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F`、public bwtの入力上限8MiB・一意sentinel・SA-IS suffix_array呼出・Vec<u16>/primary返却を確認した。誤ったBWTを候補へ接続しない。当初9bodyからの回復読込1を含め実際のunique body参照は10であり、当初上限内だったとは扱わない。compile閉包は是正後も10source/9path edgeで変わらない。是正時点でも他3コード・compile・CLI・Executeは未着手、固定契約SHAは変更しない。

テンプレ `quaternary-cts-mixed-q21/baseline_codec.rs` のe2e.rs child、candidate codec.rs child、その専用run_selfcheckを除去する。凍結modelはcopyも編集もしない。branch順序prefix→predict→range→edge→observe、型、数値式、audit更新、finish、wire/header/CRC、run_profile/run_restoreのbegin→encode/decode→elapsed→result?境界を維持する。profile状態の受け渡しと観測statementだけを追加する。無計測経路には診断Instant/集約更新を入れない（既存総timerはそのまま）。数値body/timerの除去差分allowlistをrunner内で検査し、実装後に親・独立readonly担当へ確認を返す。

## sample/state契約

ModeはDisabled/Profileの2値。外部CLIはprofileのみ。契約E2Eはmode検査用に `disabled`/`profile` を受ける小さなparserを使い、未知文字列を `Err("profile mode")` にする。componentは0/1、prefixは1..4。無効componentを先に `Err("profile component")`、次に無効prefixを `Err("profile prefix")` にし、counter/時計を進めない。Disabledでも引数検査は行うが正常呼出は時計/集約/ticketを作らずno-op。

層index=(component,prefix-1)。valid枝のprefix確定後に層の1-based ordinalをchecked_addし、ordinal%256==128だけsample。expected_samples(n)はn<128なら0、その他1+(n-128)/256、u64でoverflowを起こさない。全branch開始、層全数、sample予定を記録する。全branch完了は旧observe成功後だけ増やす。escape成功数は旧uniform byte処理成功後だけ増やし、時計を呼ばない。

sampleは枝ticketにdirection/component/prefix/ordinalを保持し、4scopeを同ticketで計時する。名前は `branch_after_prefix`（契約のparent_after_prefix）、predict、range_and_selection、observe。parent開始→predict開始終了→range開始終了→edge→observe開始終了→parent終了を一意に固定。prefix確定と抽出counterはparent前、全branch完了加算はparent後。非sampleは4scopeすべて時計なし。bucketはstarted/ended/pairs/elapsed_ns、activeとticket stageを持つ。開始・終了・加算は全対象checked演算をpreflightしてからtransaction commitする。拒否で集約stateを部分更新しない。時計端点を取った後にelapsed変換が失敗した場合、実時計を巻き戻したと主張せず、clock_attemptsとcommitted endpoint数を分けてfailureに残す。

topはtransform/payload各全区間1回、payload内Model::new/finish_audit各1回、方向別集約。Model::newのscopeはModel::new呼出そのものを囲い、Stream構築全体としない。finish_auditは全state_digest/branches/classes/entropy収集を囲う。inclusive親子を足さない。top_residual=旧total-transform-payload。sample residualは同ticket parent-(predict+range+observe)をcheckedで求め、逆転はErr。per-stratumのsumにもchecked add。payload-sample外挿をexact exclusiveとしない。推計を出す場合のみestimate=trueと全数/sample数/平均/推計を併記し、0sampleはnull。payloadのexact exclusiveは出さない。

## コード前固定の契約E2E loopと期待値

synthetic fixtureはcodecを呼ばず、実時計を使わないchecked bookkeepingに固定nsを供給する。状態は全field/active/ticketをEqでbefore/after直接比較する。hashだけでは合格にしない。plannedは以下で固定し、completedは期待Result/Err、値、stateをすべて確認した最後に加算する。

| ID/loop | planned cases | 正確な期待 |
| --- | ---: | --- |
| GOLDEN: n=[0,1,127,128,129,383,384,385,MAX] | 9 | expected_samples=[0,0,0,1,1,1,2,2,72057594037927936]、全Ok |
| STREAM: component0..2 × prefix1..5、各385 ordinal | 8 | 各層sample ordinal128,384だけ。valid枝3080、開始/完了3080、8層各全数385/sample2、全sample16 |
| STREAM scope（上記同loop内部） | 16 | 同ticket parent100ns/children10,20,30ns、residual40ns。4bucket各start=end=pair=16、elapsed=[1600,160,320,480]、residual640ns、committed時計端点128 |
| TOP: transform100/payload200/model20/audit30/total350 | 1 | 各start=end=pair=1、top_residual50。model/auditをpayloadへ足さない |
| ESCAPE: success7回 | 1 | escape7、sample/bucket/時計変更0 |
| BAD-ARG: component=[2,MAX] × prefix1..5 | 8 | Err(profile component)、全state不変 |
| BAD-ARG: component0..2 × prefix=[0,5,MAX] | 6 | Err(profile prefix)、全state不変 |
| MODE-OK: [disabled,profile] | 2 | 各対応mode、時計0 |
| MODE-BAD: [空文字,sample,PROFILE] | 3 | Err(profile mode)、時計/state不変 |
| DISABLED: valid385枝＋escape7＋top4組 | 1 | 全Ok、診断counter/clock/ticketは初期stateと同じ |
| OVERFLOW（下記固定recipe） | 14 | 全Err、全state不変。synthetic時計だけを使用 |
| LIFECYCLE（下記固定recipe） | 10 | 全Err、拒否前後state不変。finish拒否はactiveを勝手にclosedにしない |
| RESIDUAL（下記固定recipe） | 4 | 全Err、全state不変 |

上のgroupは12固定loop、cases合計83（9+8+16+1+1+8+6+2+3+1+14+10+4=83）。group行は13であり、STREAM scopeはSTREAM loop内の別比較groupなのでloop12。STREAMの3080 branchや内部scope64組はcasesの追加とせず、operations欄で別記する。期待Errは45（14 bad arg+3 bad mode+14 overflow+10 lifecycle+4 residual）、Okは38、合計83。

OVERFLOWの14recipe: (1)branch_started=MAX→admit、(2)層total=MAX→admit、(3)層sample=MAX/ordinal127→admit、(4)bucket.started=MAX→begin、(5)branch_completed=MAX→success、(6)escape=MAX→escape_success、(7)bucket.ended=MAX→end、(8)bucket.pairs=MAX→end、(9)bucket.elapsed=MAX/end elapsed1→end、(10)u128 elapsed=MAXu64+1→end、(11)committed clock endpoint count=MAX→begin、(12)ticket serial=MAX→new ticket、(13)stratum residual sum=MAX/next residual1→commit residual、(14)scope child合計=[MAX,1,0]→residual。1..13は `Err("profile counter overflow")`、14は `Err("profile child sum overflow")`。該当seed以外は合法state、拒否前後全field直接比較。

LIFECYCLEの10recipe: begin active bucket→Err(profile scope active); end inactive→Err(profile scope inactive); end foreign ticket→Err(profile ticket); end wrong direction→Err(profile ticket); duplicate end→Err(profile scope inactive); range開始前predict未終了→Err(profile scope order); observe開始前range未終了→Err(profile scope order); parent終了前observe未終了→Err(profile scope order); finish時parent active→Err(profile unfinished scope); finish時started1/ended0でactiveなしのseed→Err(profile scope count)。fixturesは毎回fresh合法stateから必要段階まで進めてseedし、1recipe1期待Err。

RESIDUALの4recipe: parent59/children[10,20,30]→Err(profile negative residual); total299/transform100/payload200→同Err; sample expected2/actual1→Err(profile sample count); branch_started1/completed0でactiveなし→Err(profile branch count)。sample過剰は同条件のactual3を第3recipe内で追加しない（plannedを増やさず、runner実データでexpected==actualを一般検査する）。

注意: 合計の確定値はcases83、Ok38、Err45。STREAM operations3080、samples16、scope pairs64、top pairs4、escape7。契約fixtureのnsは実測結果と混ぜずcontract_e2e領域だけへ保存する。

## 実入力の一意な呼出・検証

CLI `profile INPUT` 1回内の順序: 契約E2E→空Instant pair10000組を1回→入力1read→Disabled旧encode1→Profile旧encode1→Profile旧decode1→全比較→profile終了検査→JSON。compile1、CLI1、encode2/decode1、warmup0、ABBA0、canonical再encode0。overheadはcodec外、counter/loop込みの目安で機械的差引禁止。periodic同期、cold/rescale、時計分解能、計測分岐/counter負荷の偏りが残る。

INPUTは `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-current-source-native-solid-20260923-group/all.group`、2811006B、SHA256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。無計測参照は同じ数値bodyのDisabled modeで独立oracleではない。固定stats、source body/timer差分と直接比較で補う。

frame比較1組は全478750B、plain比較1組は全2811006B。Proof14は参照encode対計測encode、参照encode対計測decodeの2組、各14fieldを直接比較しCDFはto_bits。全statsは3結果の全fieldを比較、固定旧depth5 statsを各結果へ適用。encode/decode全2方向のbranch開始=完了3825340、component=[2725772,1099568]、escape742、8層counts/sampleは方向間一致し各expected_samples(n)と一致。prefix8層の具体nは既存reportに保存されていないため未観測であり、未知値を捏造しない。今回取得したnに上記事前式を適用する。

固定stats: depth5/node_count1365/node_storage196560/magic KHQCID01/header_crc_covers_depth true/frame478750/header285/payload478465/plainCRC433441561/payloadCRC3616798779/headerCRC621578488/runs889227/primary1762795/alphabet257/rank889227/length889227/escape742/branches[2725772,1099568]/grammar58735a2b7383d755/base0caac94407124a37/classes[889227,620240,1216305,889227,64372,145969]/CDF3820763.985142052（fixed値許容差1e-4、3実結果のCDF bit一致はexact）。

各方向top4bucket start=end=pair=1、全branch bucket pair=同方向8層sample合計、4scopeは同ticket。総bucket数=4top+8層×4branch=36/方向。residual negative/overflow/active/mismatchを0丸めしない。frame2枚/957500B最大、比較後参照drop、最終参照0。input/plain/frame clone・disk copy・trace0。

## failure JSONと完了の定義

schema_version=1、status=passed/failed、diagnostic_only=true、formal_speed_CPU_verified=false、full_benchmark_allowed=false、independent_reference_oracle=false。計画件数は常に存在し、未開始completed=0、process panic/timeoutでcodec内部進捗を回収不能ならcompleted=nullとunknown理由を明記する。予定から逆算しない。

contract_e2eは12loopのplanned/completedと13groupのplanned/completed/Ok/Err、operationsを分ける。codec_callsはreference_encode/profile_encode/profile_decodeのplanned各1、開始/完了各0..1。input_reads1、overhead_pairs10000、frame/plain comparison各1、proof comparison2/fields各14を別記する。個々の比較完了は全field/byte成功後のみ加算、部分成功はfirst_differenceとmatched_prefix_bytesへ記録する。実行失敗時もplanned/completed・phase・fixture・recipe・expected/actual Err・direction/component/prefix/ordinal/ticket/scope/field/indexとfirst_differenceを残す。

evidenceは最初の失敗1件、recipe最大512文字、error最大2048文字、expected/actual各最大1024文字、header preview最大64B、child stdout/stderr各最大16384B。全stateをJSONへdumpせず最初のfield/array indexと値を残すが、RAM比較は全stateを実施する。失敗JSONも正しいobjectとしてstdoutへ出しexit非zero、runnerは非zeroでも先にbounded stdoutをparse/record保存してから拒否する。panic/timeout/invalid JSONはrunner envelopeに予定と回収可能な完了だけを保存し、内部実績unknownを区別。未知schema/不足field/型不正もpassed禁止。失敗レシピ記録やpanic経路は実行しなければ動的未検証と記す。

## identity、容量、実行予算の確認方法

basisは `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-quaternary-cts-mixed-q21-20261003/report.json`、258738B、SHA256 `2866C1AD9CB11F008F3856ED2B36560B569A42734F186D3F0C6A49D469EBD853`（今回読み取り一致）。basisの163 sources + RESULT1 + 契約1 + 新4 =169 unique identities。basis report自身は別pinで169へ重複加算しない。path/sha256/bytes/mtime_utcをDateKind Stringで取り、Roundtrip DateTime→UTC ticksを使用。sources/sources_after/sources_liveの凍結163すべてを照合し、新6の今回metadataをbefore pinしてafter/liveへ比較。各入力sourceをreadlockし、SHA/bytes/ticksの検査後・実行後・liveで変更0を確認する。

runtime PowerShell7.6.5/SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139、rustc1.98.1/SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。edition2024/frame_audit/opt2/overflow-checks=yes/panic=abort/debuginfo0/link DEBUG:NONE。primitive_audit cfgは追加しない。全graph/alias/identity/容量/数値timer差分/PowerShell parserをrunner自身でnonExecute確認する。formatterはstdoutのみでfile変更なし、nonExecuteは出力rootを作らずcompile/CLIなし。

出力rootは `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-quaternary-cts-stage-profile-20261003`。最終ファイルはstage-o2-yes.exeとreport.jsonの2件だけ。EXE≤1048576B、report≤262144B、合計≤1310720B=1.25MiB、fresh≤8388608B。identity169×最大1024B=173056B、別basis pin2048B、graph/runner/config/E2E/profile/stats/failure領域合計最大87040B、JSON最大262144Bと事前projectionをrunnerで計算する。実際のserialized UTF8 bytesをwrite前にも確認し、serialization超過を切詰めて成功としない。identityは共通path/SHA/bytes/timeテーブル1つとbefore/after/live一致maskを用い、169レコード×3全文重複を避ける。各相の検査実施数と最初の差を保存し再現可能にする。

各write前: source307200B以内、出力候補件数/既存使用量/projection、空き≥5368709120+8388608=5377097728B。fresh root/全祖先のreparse/link拒否、既存rootならcreate_newで上書きせず停止。disk-budgetの契約に従う容量確認をrunner内で実施し、既存helper sourceをcompile閉包へ追加しない。source/docはfresh出力容量と区別する。compile既知582144Bの前例は上限保証でないので1MiB上限を予約し、生成後検査する。

Executeは親1回のみ。child timeout各120秒、compile1/CLI1、runtime version/formatterも有限でbounded output。全Execute wall予算300秒: compile最大120+CLI最大120+identity/JSON/終了確認予算60。runnerに単調deadlineと残り時間検査を置き、残りを越すchild開始禁止。CLIは旧encode約5.7秒×2+decode約5.7秒＋観測/E2Eの見積≤60秒（予測であり保証なし）、compile見積≤60秒、総見積≤180秒。projection成立をnonExecuteのreportで示し、120秒超過はtimeout失敗で選別再実行しない。timeoutは自分が起動したchild PID/開始時刻/descendantsだけ回収し共有processを停止しない。

このturnはplanの保存/hash/bytes/path graph/loop期待を返して停止する。次turn実装後、nonExecute/独立readonly検証が揃ってから親Executeへ進む。まだcompile/CLI/動的検証はしていない。正式median574.5624ms、CPU15%、独立holdout/categories/4native/API条件は未達のまま、goal状態を変更しない。
