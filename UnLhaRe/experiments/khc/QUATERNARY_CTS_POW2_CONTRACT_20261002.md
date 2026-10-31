# 整数CTS mixtureのpower-of-two専用化契約

前段はprogress。private integer frame proof18B106BDB873BB5B1C82EBF7F7B9B6EBB17209C8E137D9332320941D0CBECB98はpassed、実frame474730B/SHA9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD、全byte復元/canonical一致。診断encode12008.7067msは正式速度の達成証拠ではない。今回も総合goal未達、正式574.5624ms/CPU15%/holdout/4native/product条件を変更しない。

## 対象・所有権

対象はprivate CTS mixtureの同値高速化だけ。opop6基本観点とAsync/Startupを親が調査し、Intelは非該当（凍結ローカル算術で決着）。Modernizerは依存/言語更新なし、Normalizerは同値算術専用化、Performanceはvariable u128除算候補、Cleanerは参照済み旧証拠保持、Hardeningは検査順/全snapshot拒否不変、Testerは先行E2Eと直接整数比較、Asyncは単一thread/資源寿命維持、Startupは既存初期化維持。旧source/proof/rootは編集/削除しない。製品API/wire/version/配布、Git stage/commit/push、外部書込み、x86、共有cacheは対象外。

fresh source quaternary-cts-pow2/ の integer_cts.rs、comparison.rs、codec.rs、verify-full.ps1、FAILURE_PLAN.mdは一実装担当だけが所有。親は契約/結果/採否を所有。元実装担当の終了を確認済み。コード前に失敗計画を保存し、親の全source/runnerレビューまでcompile/runは禁止。parser/stdout rustfmt/nonExecute preflightだけ可。

## 仮説と反証

現在のmixtureは正規化vector own/childのQ32和から、各mass=w*own+(Q-w)*childを作る。total=Q²をchecked検査後、generic normalizeが各mass*Q/totalと剰余を計算する。sumは2^64なので、quotient=mass>>32、余り順位=(mass & (Q-1))で完全に同じHamilton結果を得られる。剰余の旧値はそのlow32bits*Q。child昇順tieを維持する。forced1でmass=Q²の場合もu128を保持してquotient=Q、remainder0。一般normalizeのkt/poolにこの専用化を混入しない。

仮説：genericの未知分母除算を省けるので、同値mixtureの局所probeでmedian時間が短くなる。反証：同一vector/weight/prefixのold/fast直接比較に一件でも差がある、invalid入力の理由/受理が変わる、または固定同条件局所probeでfast median>=old median。時間改善がなければ採用せず固定全入力candidateを走らせない。局所probeは正式codec性能/CPUの証拠にしない。

## 同値実装

旧CTS module5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7をreference_ctsとしてimportする。新integer_ctsは既存constants/types/helpers(一般normalize/kt/vector/posterior_switch/path等)をreexport。mixtureのみpower-of-two Hamiltonへ置換し、旧predict_kernel/Ctsの意味を保つ小さな接続実装を使う。Snapshot/Kernel/Nodeは旧typeそのものを使う。

順序は旧mixtureと同じweight bound→own vector→child vector→checked各mass→checked sum==Q²→normalization→vector。新normalizeはprefix、total再確認、quotient checked conversion/sum、remaining<k、remainder descending/child ascendingtie、checked増分/Q sum検査を維持する。error textは元helper/mixtureと対応させる。一般normalizeは不変。

CTS.predictはchild-free、CTS.observeは現在snapshot全体(raw/masses/derived含む)再計算一致後、全prepared node完成→commitを維持する。高速化のためにstale/modified検査やCAPを省かない。class/history/observations、leafweight、full9levelsを保持。private frame model/e2e/math/pool/BWT/packed/rangeは凍結sourceをimport。codec rootは旧673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327を機械的に同値接続し、reference_cts/newCTS/comparison importとcompare-mixture CLIだけ追加。magic KHQCIP01/fields/CRC/更新順/no-clobber/quota/CAP/通常CLIは不変。

## コード前E2E/局所probe

comparisonでは正常4116件を固定：prefix1..4ごとweights [0,1,Q/2,Q-1,Q] の20件（合法uniform Hamilton vector対を使用）、seed0x6d2b79f5のwrapping u32 LCG(1664525,1013904223)由来4096件。prefix=(index%4)+1、各legal mass=(next_state & 0xfffff)+1、旧normalizeでown/childの和Qの正vectorを作り、weightは次stateのu64値0..Q-1を使う。各old/fast mixed[4]とrawmass[4]を直接比較。scalar fixtureとしてforced1 Q²、uniform tie/weight境界も含む。invalid12件の具体値/期待理由はコード前planに固定（weight>Q、own/child0/outside/sum、prefix0/5等）。拒否はold/fast理由の直接比較、件数12を増分観測する。新unit testは追加せずstandalone RAM E2E。

同4116casesをblack_box経由で16pass、5paired rounds。round偶数old→fast、奇数fast→old。各sideの全結果digest/件数を集計し比較、直接比較4116件の代替にしない。五roundのelapsed_nsを全件JSONへ保存、medianを比較する。alloc/input構築はtimer外、同一process/同一条件、repeat変更/失敗retryなし。タイミングは診断で正式performance gateではない。

probeがpassedかつfast median<old medianなら、selfcheckの既存normal14/roundtrip14/canonical14/malformed30/model named14/assert16/CAPexact1を実行。一CLI encode/decode/canonicalを固定input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76で実行し、新frame全byteを旧frameへ比較/SHA一致、restore全byte/SHA一致。frame474730B/payload474449B/plainCRC433441561/payloadCRC3589341169/headerCRC1741345118、grammar58735a2b7383d755/base-pool9128444225deabce、枝2725772/1099568/class[889227,620240,1216305,889227,64372,145969]/CDF3788636.714502990±1e-4を照合。CLI10は旧contractどおり。演算とframeが変わったら採用しない。

## 容量・実行証拠

fresh root build/khc-quaternary-cts-pow2-20261002、8MiB。生成前peak reservation EXE1MiB+frame(1MiB+281)+report512KiB+restore2811006B+tiny2KiB=5434775Bを実評価。保持EXE/frame/reportの3file、見積り1.25MiB以内。source/input/oldframe等は再利用しcopyしない。Cargo/PDB/cache/asm/rawtrace/table生成なし。RAMケースは保存しない。

compileは一条件一回、rustc1.98.1/bundledpwsh7.6.5、opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE/edition2024/frame_audit/primitive_audit。11source/10root edge（codec、新CTS、comparison、旧model/e2e/math/pool/referenceCTS/BWT/packed/range）をpin/readlock/hash前後。旧contract/result/proof/frame/compiler/runtime/input/guardもpin。未知include/module/extern crateを拒否。基礎検証は先行proof/26identity再hashの一回確認を使い、凍結先行Executeを重複しない。最終は同immutable基礎確認と新E2E比較。

各child120秒/UTF8 stdoutstderr各65536B。EXE_beforeをbuild後validator前保存、child/parsed/frame/header/comparisonをvalidator前に保存。timeout/outputcap/startfailureもbounded record。失敗/root存在後のretry/上書き/条件緩和なし。temporary台帳は絶対path/用途/削除条件を保存。全比較後restore/tinyだけ、ancestor/descendant link/所有EXE process0/exclusive leaf/混在を確認し、同一PowerShell Remove-Item LiteralPathの非再帰削除。失敗時最小証拠/保持理由を保存。

skill台帳の各観点と採否・局所時間・正式未検証の区別を結果に残す。opopの追加行動質問は既に「7-Zip超えをするまで！」で継続指定されているため行わない。goal active、未達。
