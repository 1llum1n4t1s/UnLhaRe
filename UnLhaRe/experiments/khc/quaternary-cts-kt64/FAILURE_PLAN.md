# KT u64同値化: コード前失敗計画

契約SHA12C7F578C902D58CEF8438022513DFA63F5A587410C1BB55AD8FDDEC83E87167全文確認。新8fileだけ排他所有、旧source/proof/root/default/API/wire/version immutable。親final review前compile/candidate run禁止。parser/nonExecute preflightのみ、新unit test/fixture追加なし。

## 起こり得る失敗

- KT product/total/quot/rem幅縮小誤り、prefix外rawをactive Dへ混入またはCAPから除外、uniform非zero余りtie/forcedQ/left/sum誤り: 以下4128逐次全4値、合法各childの旧u128/新u64 product・商・余りの直接比較、scalar3groups。checked bounds m<=7650681/D<=7650684/product<=32859424687128576<2^55。一般normalize/poolはreference alias不変。
- prefix/CAPの検査順や拒否text変更、illegal受理: 8入力exactErrを両実装で比較。旧types/posterior/pow2mixture/snapshot再predict/CAP/prepared→commit/audit seedは機械的コピーで保持。
- wire/model static alias/helper visibility/sourcegraph誤接続、hot runtime dispatch/inner timer混入: root reference helper alias、oldwire=pow2/newwire=kt64、同modelを2具体typeでcompile。旧modelcrate→superだけ、旧wiremain/import/entry接続だけ。14unique/14edge(11root+2model+newwire→oldE2E)。内側timerなし。
- timed入力構築/alloc混入/DCE/順序/pass/count/digest/ns/中央値誤り: timer外構築、black_box関数/入力/結果、5paired×16pass、66048/roundside・330240/side。直接4128比較をdigestで代替しない。局所improved=falseは数値failureではなく採用保留の反証、正確性passedならselfcheck/profile一回を行う（親確認済み）。正式性能gateへ流用しない。
- old/new encode/update/CRC/range/history/frame差、decode partial復元、CAP/改変snapshotguard劣化: frozenE2E selfcheck一回normal14/byte14/canonical14/malformed30/model named14/assert16/CAP exact1。固定ABBA4frame直比較・候補decode全2811006byte直比較1。全入力canonical再encodeは追加しない。
- ABBA/reset/drop/読込/計時位置の変化、前run残り/warmup追加/retry: pow2,kt64,kt64,pow2各一回。同位置encode直前→戻り後だけInstant、stats/frame比較/JSON/drop除外。input/baseline各一回bounded read、frame一枚ずつ比較→drop。4run後decodebaseline一回/全plain比較→drop。run progress flush＋final/partial JSON。120sec/CLI一回、timeout時count縮小やretryなし。
- source/pins/旧basis48/mtime型混在/環境/CWD/EXEbefore/parsed証拠/容量欠落: readlock/hash前後、旧basis48UTC/date-kindstring一致、old Execute無し、CPU/OS/compiler/runtime/path/hash/bytes/mtime/CWD事前保存。fresh8MiB・scalarpeak1572864B、child各120秒/UTF8各65536B、bounded start/timeout/cap record。全raw/parsed/比較をvalidator前保存。
- frame/restore/inputcopy/Cargo/PDB/cache/asm/rawtrace/table/temp生成・清掃で旧証拠破壊: EXE/report2fileだけ保持、temp0/deletion0。終了root links/混在/ownedprocess0/2file/guard/48basis旧EXE不変確認。Git/外部write/x86/sharedcache無し。

## compare-kt固定

合法4128: prefix1..4×raw8([0;4],[CAP,0,0,0],[0,CAP,0,0],[0,0,CAP,0],[0,0,0,CAP],[1;4],[CAP/4;4],[CAP-3,1,1,1])の32＋4096LCG。seed0x6d2b79f5、wrapping1664525*s+1013904223、raw各next%(CAP/4+1)、prefix=index%4+1。referenceKT対newKT全4値とproduct/商/余りを逐次直接比較。timed16pass×5paired old-new/new-old/old-new/new-old/old-new、case配列不変。

拒否8: k0/[0;4]→invalid prefix、k5/[0;4]→invalid prefix、k4/[CAP+1,0,0,0]→raw observation cap、k4/[u32MAX,0,0,0]→同、k4/[u32MAX;4]→同、k0/[u32MAX;4]→invalid prefix、k1/[0,0,0,CAP+1]→raw observation cap、k4/[CAP,1,0,0]→同。

scalar3groups: forcedk1→[Q,0,0,0]、zerorawk3でquot[1431655765;3]/rem[1;3]/left1→[1431655766,1431655765,1431655765,0]（child0tie）、raw[0,0,0,CAP]のk1/2/3でprefix外CAP保持＋activeD限定。同値直接比較、別timed入力を追加しない。

## 固定frameとdecode

ABBA4encode＋1decode。frame/header/payload474730/281/474449、CRCplain433441561/payload3589341169/header1741345118、runs889227、primary1762795、alphabet257、rank/lengthtoken各889227/escape742、枝2725772/1099568、grammar58735a2b7383d755/base-pool9128444225deabce、classes[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990±1e-4。frame全比較4×474730、plain全比較1×2811006。fullcanonicalはnormal14だけ、固定全入力再encode無し。decodeheaderCRCはbaselinefieldも保存する。

局所/ABBA診断で正式574.5624ms/CPU15%/observer/terminal/holdout/4native/productを達成したと主張しない。一般8MiB保証/heap-write-syncfailure注入/一般handle-safe抽出未検証。opop採否/全観点/残gateは親所有、全goal active未達。
