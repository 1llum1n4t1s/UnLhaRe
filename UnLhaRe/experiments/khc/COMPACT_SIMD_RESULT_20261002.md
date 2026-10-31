# Compact商候補: 数値E2E結果と次の実装境界

前goal turnはfull SIMD候補の正確さ検証でPROGRESS。今回もPROGRESS: 正式比較のterminalを確定した後、静的配置証拠に基づく別kernelを実装し、独立商oracleとの照合に成功。速さ/製品採用/7-Zip超えは未証明。

## 静的probeの証拠

- `build/khc-simd-layout-20261002/report.json` SHA256 `CA1522EDF48D3166B6234DA89D8DFADE3AD2AD9AC469FB694702C7EE12373DA2`、3 checks / 2 compiler CLI / 7 identities。helper9A135D48AD9C80B02B5BF916301EBBA0F95ED3EA578B6E0B0563A4E6E38645C7をrustc1.98.1でlib/emit=asm、opt3、overflow-checks=yes、panic=abortとして構築。full codecの命令/実行時間とは別のstandalone probe。
- asm23877B、SHA256 `EC30EF8916CBF489A1EE0F76E4F1DE8F9BE95D90D5467C62C29274A08E1543AD`。size getter即値/aliasでRatio24B、4Ratio96B、4CTS Result96B、4入力Result128B、4plain商32Bを確認。新Option全体のsizeは未測定で、32Bと主張しない。
- scalar branchにもSSE2 divpdが2本、AVX2 helperにはvdivpdが1本。ratio4 bodyは825 static instruction lines、216B local stack allocation、AVX helper/2panicへのcall。これは全分岐/未実行panicを含む静的数で、動的instruction count/サイクル/速度差ではない。`simd-layout/analysis.json`にsymbolと解析を保存した。
- 全生成物29355B、EXE/PDB/Cargo/cache/traceなし。2MiB guardを満たす。

## 新kernelと数値証拠

- `compact-simd-quotient/exact_div.rs` SHA256 `978B932A7D0CFAA7C8090DB75C6928E7746798F91213CA7AE89231810A9C222D`。元helperを2明示置換で対応コピーし、旧ratio4/dispatchは不変。新try_nonzero4は全laneが適格なら厳密商のSome([u64;4])だけを返し、ガード/補正/certificate不一致はNone。p=q*dの恒等式をchecked加減で保存し、p<=nかつn-p<dを最後に要求する。
- numeric adapterは実try_nonzero4を呼び、None時は元ratio4へ戻す。成功にはCOMPACT=64を付けるがwire/商には使わない。旧flagsのfingerprintとは異なる診断分類である。
- `build/khc-compact-simd-20261002-coverage-repair/report.json` SHA256 `C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935`、status `compact_batch_numeric_verified_not_codec_or_timing`、32 checks / 87 CLI / 13 identities。UTC2026-10-01T18:37:13.5722273Z〜18:37:17.3991093Z。
- opt2/opt3、overflow-checks=yes、scalar/AVX2の各条件で9293629 records / matched9293629 / batches2323408、compact8398832 / legacy shifted393693 / estimated375489 / native125326 / errors289、fingerprint `f02dbdcb00adbe1d`。各recordを独立u128直接商/余りへ実比較し、全4要約が完全一致。14 BigInteger商×4条件、混在lane、tail1/2/3、引数拒否も成功。
- legacy down0/up1618/certificate_fallback0は元fallback処理の診断カウンタだけ。compact kernel内のDOWN/UP/None原因を個別計数したわけではなく、全kernelで補正/拒否が0だったという意味ではない。
- audit SHA `AB7222684CD2AC565CA48B18D58FDA22A821F50D8C58BC60DE027E77A14643C3`、verifier SHA `7EF4DF0E46BFDBDF8C3F8509CC37FF46B2FAEE6179F84B5F7858DBDCDEA19284`。helper/auditの全文明示対応をverifier内で実行し、verifier-correspondenceの全文も終了後に照合。全13 identityレコードを再hash/length確認。

## 初回失敗と容量

- 初回 `build/khc-compact-simd-20261002/report.json` SHA `9EE01DA2AA07C414541ADBB2326134B71E9F4327FF9993E1A49E938220FD6C12`、最初のscalar auditが `coverage/matched invariant` でexit2。旧CLIのestimated/down必須条件を、新COMPACT分類へ置換し忘れていた。kernel自体/入力/独立oracle/比較条件を変えず、compact>0・legacy fallback>0・matched==recordsに加えて全診断分類合計==recordsを要求する条件に修正。source correspondenceへ7番目の置換を記録し、別fresh rootで全4条件を完了した。
- 成功root363563B(約355KiB)、PDB0、関連process0。8MiB guardを満たし、/DEBUG:NONEで生成した。raw数値/trace/新Cargo target/cacheなし。失敗reportとEXEは原因再現用に小さく保持。今回の正式比較はattempt1400Bだけ、static probeは29355Bで、巨大生成物は作っていない。
- `git diff --check -- UnLhaRe` exit0。製品の既存dirty files、x86、共有cache、Git stage/commitには触れていない。

## 次の実装

1. 新別full候補をBayes-dominant/旧integer heavyから明示対応で派生する。KtTableへ一度だけBackend autoを保持し、try_nonzero4へのposterior APIを追加。KT大型分母・alpha・next_weightは旧厳密整数式のまま。
2. Tree.updateではleafの旧更新後、4件groupの入力を変更前node/snapshotから準備し、try_nonzero4でSomeの場合だけplain商配列を使う。Noneなら元のlane別posterior計算を旧leaf→root位置でそのまま実行する。入力/戻り値の4Result配列を正常経路へ残さない。エラー/部分更新/世代/poisonを変更しない。生成済みPredictionの深さ別index一意性を根拠にし、捏造private Predictionの同値まで主張しない。
3. 新source/EXE/numeric proofを固定し、auto/checked-auto/scalar/checked-scalarの7入力full frame/stdout/restore、旧decoder双方向、安全拒否を32MiB以内でE2E検証。compact helperが実codecで使われていることをsource対応と個別bounded観測で確認する。
4. full成功後だけ、新EXE/sourceに固定した別正式比較を一度だけ実施。旧terminal integer/Q15/SIMD候補の再試行ではない。既存固定gate/CPU/CLI境界/9round/順序は維持する。

Reachable Node weightのu32化は別案。alpha=floor(Q/(after+1))>=7、retained=Q-2alpha、posterior<=Qからnext_weight<=Q-alpha<=Q-7<u32::MAX、fresh/leaf weight Q/2も適合する数学的候補だが、現Nodeはu64のまま。今回混ぜず、必要なら別契約/配置実測/full E2Eで検討する。

full codec/速度/四native/holdout/カテゴリ/同境界decode/製品安全性/総合7-Zip超えは引き続き未達。goalはactiveを維持する。
