# ABBA phase profile: コード前失敗計画

契約SHA128DFCF78987C1F3F9F8960DF452B905A4AD4C26CE1CCA6FEE1630FEB81BA80A全文確認。新7fileのみ所有、旧全source/proof/root/frame immutable。親final review前compile/run禁止、parser/stdout rustfmt/nonExecute preflightのみ。新unit test/fixture/数値変更なし。

## 起こり得る失敗・反証

- static CTS aliasを誤接続しold/pow2が同じ型になる、runtimeenum/virtualdispatchでhot経路を変える、sharedmodel helpervisibility/Result/private aliasを誤る: root一般helperはreference alias、各wireのsuper integer_ctsだけ分岐。12unique sources/12edges(10root+2wire→same model)と具体aliasを静的確認。
- tree/count/hash/serial/snapshot/CAP/準備commit/CRC/range/quota/grammar/entropyを計測のため変える: 旧model/wireの機械的コピー＋timingのみ、各ABBA run全frame474730byteを凍結baselineへ直接比較して全固定statsを照合。
- 時間境界ずれ/returncopy漏れ/escape混入/forced省略/選択serialずれ、二重計算/状態変更: 下記phase境界固定。同じserial%1024==0のみ7phase、prediction追加再計算禁止。forced通常interval含む、escapeはrange sample除外。
- monotonic clock順逆/elapsed変換/加算/count overflow、samplephase漏れ/過剰/component/prefix違い/前runthreadlocal残存: checked u64 ns/count集計、run reset、3736samples×7phase、component2/prefix4合計3736、sample serial first0/last3824640、成功branches3825340をvalidatorで確認。選択とphase countを実観測。
- BWT/setup/modelinit/digest/flush/metadata重複を誤ってphase合計として主張、sampleを確定CPU時間へ外挿、ABBAを正式median/gateと呼ぶ: 包含関係をJSONへ明記。phase和一致を強制しない、subsetbias/clock/CPU scheduling/配置変更を未分離と報告。
- 4run順序/入力/BWT/modelreset/drop違い、warmup/repeat追加、4frame全部を保持、途中失敗後retry: old,pow2,pow2,old各一回、input/baseline bounded read一回、1frameずつ比較→drop→次run。途中完成/失敗recordをbounded JSONに含め、timeout120sec/noRetry。
- sourcegraph/pins/旧basis36/CWD/mtime/compiler/runtime/CPUmodel/OS証拠漏れ、EXE/parsed保存順/容量漏れ: 旧basis36一回再hash、pin/readlock前後、EXE_before/childparsed/全runmetric/比較をvalidator前保存。新root8MiB・EXE1MiB+report512KiB=1572864B、保持2fileのみ。UTF8各65536B。
- frame/restore/input copy/trace/temp生成/清掃で旧証拠を壊す: diskはEXE/reportのみ、temporaryなし。終了root link/混在/所有EXEprocess0/2file/guard/immutable確認。新root外を削除しない。

## 固定runと全byte観測

ABBA=[old,pow2,pow2,old]、warmup0/repeat追加0。各run input2811006/primary1762795/alphabet257/runs889227、tokens各889227/escape742、枝2725772/1099568、classes[889227,620240,1216305,889227,64372,145969]、grammar58735a2b7383d755/base-pool9128444225deabce、CDF3788636.714502990±1e-4。frame/header/payload474730/281/474449、CRC433441561/3589341169/1741345118。全frame比較4件×474730byte、hashだけの証明禁止。今回decode重複なし、先行復元E2Eとは別の保証。

## all phase境界と包含

| phase | start→end・重複 |
|---|---|
| full_encode | wire run_profile内でencode呼出直前→結果受取後。下記phaseをすべて包含、frame比較/JSON/dropは除外 |
| bwt | bwt(input)呼出前→戻り値受取後、割当を含む |
| payload_setup | encode_payload開始→run/next/alphabet/active構築完了。model初期化は含めない |
| model_initialization | Stream::new(Encoder::with_limit含む)前→戻り値受取後。model/math/CTS/table/tree初期化含む |
| payload_loop | run処理loop直前→active/consumed最終検査後。全token/escape/history更新を含む |
| final_digest | stream.finish_audit呼出前→戻り値受取後。base/pool全値digest/集計コピーだけ |
| metadata_crc_frame | encode_payload戻り後→metadata/CRC/header/frame組立完了。range.finish(5flush)は含めない |

bwt/setup/init/loop/digest/metadataは互いに非包含、ただしfull_encodeは全包含。range.finish/関数戻り/一部drop/clockaggregationはfull_encode内の残差として残す。phase和一致のassert禁止。

## sampled7phaseと固定選択

serial0,1024,...,3824640の3736branch/run。same branchだけのmodel_predict外側（返却copy含む）・cts_predict内側・pool_predict内側・range_interval外側（通常forced含む/escape除外）・model_observe外側（呼出戻り後）・pool_update内側・cts_observe内側。innercts/poolは各outerの包含、sampletimeを全部足して全体時間としない。1run各phase count3736、7phase合計26152、4run合計104608。component[2]/prefix[4] countsは実観測して各3736への和だけを固定、分布値は推測で設定しない。threadlocal reset前残存を捨て、各run後aggregate copyをrecordへ保存。全CTS.observe再predict/検査/commitは元のまま。

H1/H2の採否・opop台帳は親所有。正式speed/CPU/holdout/4native/product/一般8MiB対応は未検証。診断child TotalProcessorTimeをmachine CPU15%と同一視しない。外部write/Git/version/x86/sharedcache無し、全goal active未達。
