# CTS KT正規化の同値u64専用化・固定ABBA契約

前段progress。phase proof359A98D303CC898354AB346BD0A3EAB896B49D03C721EEAD46A3CA4A692B0B7F passed、4全frame一致、pow2の同process計測付きencode平均12.2025%短縮、loop98.57～98.73%、選択sample CTS predict約69%/observe約83%。全goal未達。今回はKT normalizeだけをu64へ同値専用化し、pow2を比較基点とする。全7-Zip要件を局所改善へ縮小せず、正式574.5624ms/CPU15%/observer確認待ち/terminal protocol/holdout/categories/4native/productを変更・起動しない。full_benchmark_allowed=false。

## 所有権・境界

新source quaternary-cts-kt64/ の integer_cts.rs、model.rs、old_wire.rs、new_wire.rs、profile.rs、comparison.rs、verify-kt64.ps1、FAILURE_PLAN.md の8fileを一実装担当が排他所有。親は契約/採否/結果/全観点を所有。前段担当の編集停止回収済み。旧全source/proof/root/frame、製品default/API/wire/version、Git stage/commit/push、外部write/公開、x86/sharedcacheは対象外。コード前失敗計画を保存。親最終review前はcompile/candidate run禁止、構文parser/nonExecute preflightのみ可。他の作業者の変更を戻さず適応する。

opop基本6観点＋Async/Startupを親がこのprivate codec scopeへ限定して調査・台帳確定。Intelは凍結ローカル算術で非該当。追加質問はgoal継続が明示済みなので行わない。旧Executeの重複実行なし、旧proofの再hashを基礎検証とする。

## 候補と反証

H1: 同じKTのHamilton正規化をchecked u64商/余りで計算すると局所probeが短くなる。速くなければ採用しない。H2: CTSへの接続でも同条件の4encode ABBAで候補が短くなる。局所だけ速く全encodeが改善しなければ統合採用を保留する。正式gateに診断平均/最速値を使わない。

旧ktはprefixを先に検証、4raw全体のu64和をchecked計算、CAP超過を拒否し、prefix内m[j]=2*raw[j]+1をu128で作り、generic normalize(m,k)、vector(result,k)を呼ぶ。CAP=3825340、Q=2^32。合法入力ならraw[j]≤CAP、m[j]≤7650681、D=sum(prefix masses)≤7650684、product=m[j]*Q<2^55。よって商floor(product/D)と余りproduct%Dはu64で正確、旧u128と同じ。sum商/left=Q-sum/Hamilton余り降順＋child昇順tie/最終vectorは変更しない。rawのprefix外はDへ入らないがCAP全4和へは入れる。一般normalizeやpoolの拒否/公開意味は変更しない。

integer_cts.rsは凍結pow2 module DCFD5CF8F9D408174840194CA3D0AF38F90EB938172C5A51EA2B85BA90427B28をコピーし、kt reexportを取り除き、専用kt関数だけ追加。mixture/Q² bitshift、posterior/update_kernel、Node/Kernel/Snapshot、9階層/6class/history/observations/CAP、predictとobserveの全Snapshot再predict比較、準備後commit、audit seedを同じ意味で保持。ktは現在のprefix/rawcap拒否順と文字列を保持。狭幅checked guardは合法旧入力で新たに失敗しないことをboundsと比較で示す。

## 静的接続・source graph

rootは同じfrozen helpersをimport: fixed_math A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD、integer_pool7135CC9E6F5CF57191DC6EE409D8C32C8EF9FEB9C1B6B2D7B18C7B436F56C625、referenceCTS5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7、pow2CTS DCFD5CF8F9D408174840194CA3D0AF38F90EB938172C5A51EA2B85BA90427B28、newCTS、BWT810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F、packed4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D、rangeCAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129。rootのcrate::integer_ctsは一般helper用reference alias。

両新wireは凍結integer frame codec673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327を機械的コピーし、main/CLI/importを外してroot helper aliasへ接続。共通新model.rsは凍結BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9からcrate依存をsuperへ変えるだけ。phase samplerを入れず、数値内側のtimerも無し。old_wireのCts aliasはpow2、new_wireはkt64。runtime enum/virtual dispatchをhot CTS経路へ追加しない。tree/count/hash/update/CDF/entropy/digest/CRC/range/CAP/quota意味を変更しない。

予定unique14source/14edges: rootからoldwire/newwire/math/pool/refCTS/pow2CTS/newCTS/BWT/packed/range/comparisonの11edge、各wire→common modelの2edge、newwire→凍結e2e824DE9E08FA2EC069FE0D935EC7E2FE58EFD38FE813D5D49F545AD156AABE3E1の1edge。rootを含むunique14、resolved unique13。未知include/module/extern crateを拒否。newwireはrun_selfcheck()で凍結e2eを呼ぶ。両wireの数値本体差分はCts aliasだけ、newwireにE2E/全入力復元wrapperが追加される。

## コード前固定standalone検証

CLIはcompare-kt、selfcheck、profile INPUT PRIOR_FRAMEだけ。全child exit/stdout/stderrをbounded保存し、parsed値をvalidator前に保存。新unit testなし。以下はコード前固定の最小standalone比較/E2E。

### compare-kt

4128合法ケースをRAM direct compareする。32境界=prefix1..4×raw8組([0;4]、[CAP,0,0,0]、[0,CAP,0,0]、[0,0,CAP,0]、[0,0,0,CAP]、[1;4]、[CAP/4;4]、[CAP-3,1,1,1])。4096 pseudo randomはLCG seed0x6d2b79f5、next=wrapping(1664525*s+1013904223)、各raw=next%(CAP/4+1)、prefix=index%4+1。同じ入力のreference::kt（u128一般）とcandidate::kt（u64専用）の全4値を逐次比較。old/pow2のktは同じreference reexport。

追加8拒否ケース・expected理由: prefix0/zeros→invalid prefix、prefix5/zeros→invalid prefix、prefix4/[CAP+1,0,0,0]→raw observation cap、prefix4/[u32::MAX,0,0,0]→同、prefix4/[u32::MAX;4]→同、prefix0/[u32::MAX;4]→invalid prefix（順序）、prefix1/[0,0,0,CAP+1]→raw observation cap（prefix外もcap）、prefix4/[CAP,1,0,0]→raw observation cap。旧/新それぞれexact理由照合。

scalar3 groupsをtimed入力と別に直接照合: forced prefix1で[Q,0,0,0]、zero raw uniform3でquot=[1431655765;3]/rem=[1;3]/left1→[1431655766,1431655765,1431655765,0]、prefix外CAP raw[0,0,0,CAP]でprefix1/2/3の同値正規化（全4cap保持/activeD限定）。合法全ケースのproduct≤u64を実際にchecked比較し、旧商/余りと狭幅商/余りも逐次照合。ハッシュだけの数値証明は禁止。

局所probeは5paired rounds×16passes×4128cases、各round side66048calls、total330240/side。order old-new/new-old/old-new/new-old/old-new。同じblack_box関数pointer/入力/result、digest全4値、countとdigest双方一致、elapsed_ns各5/中央値/improvedを保存。生数値列は保存しない。これは局所診断だけで全codec/正式gate証明ではない。

### selfcheck

候補wireの凍結e2eを一回実行。normal14/malformed30/model named14/reject assertions16/CAP exact1の既存全byte/guard理由/無変更性チェックを保持。tree/CDF/range/CRC/escape/serial/Snapshot拒否を変更せず、追加fixtureなし。

### profileと全入力復元

一process、input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、baseline474730B SHA9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFADを各一回bounded read。固定pow2/kt64/kt64/pow2、warmup0/repeat追加0。両wireのrun_profileは同じ位置でencode直前→戻り後だけInstant計時、stats formatting/frame比較/JSON/drop除外。内側sample/timer無し。各frameをRAM全byte比較474730→dropして次run。各run progress JSONをflush。4run後、候補decode(baseline)を一回だけ実行しplain2811006全byteをinputへ比較→drop。全入力canonical再encodeは追加せず、4frame一致とnormal14のcanonical E2Eと区別する。

各encodeと候補decodeはframe/header/payload474730/281/474449、plain/payload/headerCRC433441561/3589341169/1741345118、runs889227、primary1762795、alphabet257、tokens各889227/escape742、枝2725772/1099568、grammar58735a2b7383d755/base-pool9128444225deabce、classes[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990±1e-4を照合。headerCRCはbaseline fieldも保存。全frame比較4/全plain比較1。partial/完成runも失敗時bounded JSONへ含め、timeoutでは再試行/4run削減無し。

## runner・環境・容量

fresh output build/khc-quaternary-cts-kt64-20261002、8MiB。保持EXE/report2fileのみ、peak予約EXE1MiB+report512KiB=1572864B、見積1.25MiB以下。frame/restore/inputcopy/Cargo/PDB/cache/asm/rawtrace/table/tempを作らない。source新8file/contract/全graph/旧phase48identities/旧proof/results/frame/compiler/runtime/input/guardをpin/readlock/hash前後、prior Execute無し。旧phase report/result/EXEを固定SHAで確認。48basisのDateTimeはUTC同士またはdate-kind stringで比較しISO文字列との型混在誤判定を避ける。

一度のrustcopt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE/edition2024/frame_audit/primitive_audit。rustc1.98.1 path C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、bundledpwsh7.6.5 path C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139。

environment/source-CWD/path/hash/bytes/mtime/CPUmodel/logicalcount/OSは計測前保存。child各120秒、UTF8 stdout/stderr各65536B、開始/timeout/outputcapもbounded record、no retry。一compile後EXE_beforeを即保存してvalidators、各child/raw/parsed全結果をvalidators前保存。profile4encode+1decodeだけ、起動回数1。child TotalProcessorTimeは診断のみ、machine CPU15%とはしない。

終了時rootのlinks/混在/ownedprocess0/2files/容量と旧48basis/source/EXE不変を確認。保存proof/resultは保持し、一時物を作らず清掃削除も無し。親は採否/全観点/残正式gateを結果に保存。今回正常ケースでも一般8MiB対応は主張しない。goal active未達。
