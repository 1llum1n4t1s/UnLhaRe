# 5特徴整数CTS poolのprivate実frame・E2E契約

## 成功済み根拠と範囲

前段はprogress。整数pool全入力proof A0A586A487E8761E075CD3B157866CD5C0183AEC94106D9E6556199688C11A01と結果CC5139C868DC26B20CF333E84EE4B4E35E18853FF8E91BC2561FF3E78C94E73Bがpassed。CDF entropy＋escape3794572.714502990bitsは予算3866504bitsを通過した。次は同整数モデルを実range streamへ接続し、固定全入力の実frameサイズとbyte-exact復元、正準再符号化、異常拒否/no-clobberを一条件で確認する。公開API/製品wire/LHA method/version/配布は変更しない。magic KHQCIP01は新しいprivate研究形式で、他研究形式や既存LHAとの互換性を主張しない。

新dir quaternary-cts-integer-frame/、fresh root build/khc-quaternary-cts-integer-frame-20261002。一担当がmodel.rs、codec.rs、e2e.rs、verify-full.ps1、FAILURE_PLAN.mdを所有する。parentが契約/統合結果を所有する。コード前に全失敗計画を保存し、全担当は旧source/proof/rootを編集しない。parent最終レビューまでcompile/候補runは禁止。parse/stdout-only rustfmt/非実行preflightだけ可。

## 凍結モデルと更新順序

主kernelはfixed_math A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD、integer_pool 7135CC9E6F5CF57191DC6EE409D8C32C8EF9FEB9C1B6B2D7B18C7B436F56C625、integer_cts 5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7をimportする。先行整数契約EE130558C966D6C96DE8887050A01D39FA3FDC59802AC70A867BC0DD53BE28FAとopportunity5DEC4BD1AAAC58BEFB8F933CD5A2EB48D82CC911DAA9C631B044C3F00631003Fのcanonical演算を変えない。

tree/nodeID/full区間class、4608 global weight row、既存4table/count/hash/rescale、6class/過去8child CTS履歴、rank context、run recent/previousを完全に維持する。model.rsには数値kernelやf64近似を再実装しない。Countsは正u16[4]、初期1、observedに+2、全total>=32768で各ceil-half。cached totalの有無は自由だが全値/更新結果を変えない。

branch予測はcomponent/context/node/symbol/recent/previous/合法prefixからCTS snapshot→pool予測/CDFを作り、observed childを受け取らない。encodeは既知tokenからchildを選ぶが予測featureへ混入しない。decodeは未知tokenのpathを作らず、node＋limitからprefixを決め、range slot/CDFからchildを選んで次nodeへ進む。forcedprefix1も通常interval(0,32768,32768)としてrangeへ通す。全枝でCTS/count/historyを更新する。

次weight・4countを準備してからcommitする。内部BranchPredictionのfieldsを隠し、serial/current weights/counts等でstaleを検査し、CTS.observeの拒否より先にpool/tableを変更しない。fallible準備→CTSの全snapshot検査/commit→非fallible pool/count/serial commitとする。private helperを外部APIにしない。

next-useはencoderだけでrankを作る。初登場順alphabetをactive listへ入れ、encoderはhead削除後active.len()+1、decoderは削除前active.len()をrank limitに使う。rank0は消滅、非zeroはhead削除後rank位置へ再挿入。length contextはfloorlog2(rank+1)。recent/previousはlengthとescapeの完了まで更新しない。previous=(exponent(rank.saturating_sub(1)),exponent(length-1))、recentは旧4bit run記号規則。grammar key用previous full rankも維持する。

length token=min(length-1,255)。token255ではlength256でもescape byte0を一個出す。escapeはtotal256/frequency1で最大4bytes、上位終端group0/4bytes継続/remaining超過を拒否し、pool/CTS/countを更新しない。

## private frame・資源上限

rangeは凍結direct-token/multi_range.rs CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129をimportする。CDF total32768/frequency>=2、escape total256を使い、5回flush、decodeの全payload消費＋code0を維持する。primitive report3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AEは先行の別証拠で、新モデル全体の保証にはしない。

36-byte LE headerのmagic以後はlength/primary/alphabet count/payload bytes/plain CRC/payload CRC/header CRCの7u32。正準packed alphabet4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734Dをimportし、33..245byte metadataを付ける（header69..281byte）。header CRCは[0..32]+[36..header_len]、payload/plain CRCは別。payload長からmetadata境界を得る正準width/rank/sentinel/padding検査、inverse BWTのprimary/sentinel数/alphabet/LF全cycle/出力長検査を維持する。BWT source810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132Fをimportする。

prototypeはinput<=8MiBに加え、全CTS class/node observations<=CAP3825340とpayload<=1MiBを明示する。8MiB以内の一般入力がすべて成功するという保証ではなく、一般cap/配布Limitsは別段の未完了事項。cap到達やquota超過で途中frameを公開しない。

新payload上界はmin(32*n+6,1MiB)、n=入力長+1。一runのrank/lengthは各depth<=7、各CDF intervalは正規化range>=2^24からfrequency>=2なので最大2 shift、escapeは最大4bytes/runで各最大1 shift。run<=n、計(2*14+4)*n＋終端余裕6。旧8*n+32上界を流用しない。frame上界は1MiB+281、header内payload>=5。quotaはRAMにも適用し、大きいraw trace/tableを保存しない。

CLIはencode INPUT FRAME、decode FRAME RESTORE、canonical FRAME（decode→reencodeの全frame byte比較、出力なし）、selfcheck（下記RAM E2E）を持つ。publishは全符号化または全復元/CRC成功後だけcreate_new、既存出力を保持し、自分がcreate_newしたpartial write失敗だけ清掃する。固定rootの親/配下reparseをrunnerで拒否する。一般抽出先のhandle安全性・製品API統合をこのlabの保証にしない。

## コード前失敗計画・E2E

causal順序/child漏れ、nodeID/合法prefix/forced1、history timing/hash/count rescale、same-snapshot/stale/cap/非mutation、range rounding/slot/consume/終端、escape境界/非正準/overflow、metadata/CRC/LF、資源上限、CLI/既存出力/部分公開、source graph/pins/環境/容量/タイムアウト/失敗証拠を最初に列挙する。コード後のunit testを新設せず、standalone自己完結E2Eとして入力→encode→decode→byte比較→再encode全frame byte比較と再現JSONを返す。

RAM正常E2E14件を固定する：empty、constant0長1/2/255/256/257/383/384/16639/16640の9件、全256 byte値を4回並べた1024byte、最高値255を含む疎alphabet64byte、seedを実装前失敗計画で固定する4096byte LCG入力、固定textを128回反復した入力。normal14/byte roundtrip14/canonical14を増分計測する。

RAM異常E2E30名を固定する：short_header、old_magic、bad_magic、input_length、primary_field、alphabet_zero、alphabet_over、payload_short、payload_quota、payload_derived_bound、header_crc、payload_crc、plain_crc、metadata_padding、metadata_sentinel、metadata_width、metadata_rank、range_prefix、range_gap、range_truncated、range_trailing、range_termination、sentinel_count、primary_sentinel、lf_cycle、active_early、active_remaining、escape_noncanonical、escape_fourbytes、escape_remaining。targetより手前で拒否しないよう必要なCRC/metadata/lengthを正しく作り直し、各名の期待拒否理由を実装前失敗計画へ固定する。forgeはe2e.rs内のRAMだけで、codecの正常guardを無効化しない。必要なprivate token/byte/frame組立hookをframe_auditだけで用意する。一般heap/write/sync failure注入は実施しないなら未検証と記載する。

別途model拒否はCAP exact/over、stale/modified snapshot、prefix/child/row/weight/countの非法を必要範囲で検査し、件数と全状態の直接比較対象を実行前に固定する。CTS audit seedはprimitive_auditでのみ使用する。架空hash比較だけで非mutationを主張しない。

固定input all.group2811006byte SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76は一CLI encode、一CLI decode、一CLI canonicalで確認する。復元はrunnerがinputとの全byteを逐次比較しSHAも記録した後、temporary restoreだけ削除する。frameを保持する。encode/decodeでprimary1762795/alphabet257/runs889227/escape742、枝rank2725772/length1099568、全grammar58735a2b7383d755、base table/pool digest9128444225deabce、class observationsを成功proofへ照合する。CDF entropy3788636.714502990bitsを1e-4内で照合する。digestは補助で、実復元は全byte比較を行う。

CLI filesystem E2Eはzero-byte temporary inputのencode/decode、既存16byte sentinel出力へのencode/decode拒否、missing source/parent、unknown operation/引数不足を確認し、拒否時output absentまたは既存全byte不変を観測する。各temporaryの絶対path/用途/削除条件をrunnerに記録し、リンク/使用中/他作業混在を検査して同一PowerShellでRemove-Item -LiteralPathする。

actual frame<=483599byteならsize gate true。それでも正式speed/CPU/holdout/categories/4native/製品APIは未達で、full_benchmark_allowed=false。size falseでも復元/異常結果を保存し、当候補の正式benchmarkは起動しない。固定574.5624ms/CPU15%等を緩和せず、過去terminal条件や確認待ちobserver変更を再実行しない。

## 実行ラッパー・容量

one opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE、edition2024、frame_audit＋primitive_audit、rustc1.98.1/bundledpwsh7.6.5。compile graphはcodec/model/e2e/凍結math/pool/CTS/BWT/packed alphabet/rangeの9source、rootから8import edgeを予定する。未知module/include/extern crateを拒否する。source/contract/先行proof/result/compiler/runtime/input/guardをpin/readlock/hash前後照合する。非実行preflightは容量/scalar式/環境/hash/graphを実評価する。

new root8MiB予算、retained見積り1.25MiB以下、reserve EXE1MiB/frame(1MiB+281)/report512KiB、temporary restore2811006byte＋tiny fixtures<=2KiB。合計peak reserve<8MiBを生成前に計算し、前後guardを実行する（OS強制write quotaではない）。全child120秒/各stdoutstderr65536bytes、frame/EXE/reportだけ保持する。Cargo/PDB/cache/rawtrace/table/入力複製を作らない。

EXE_beforeをbuild直後validator前に永続化しreadlockする。各child record/parsed結果/実frame identity/復元comparisonはvalidator前に保存する。timeout/cap/開始失敗もbounded partial出力とstageを残す。失敗後の同条件retry/root上書き/条件やtolerance緩和をしない。temporaryは最小失敗証拠を保存し用途終了/idleを確認して削除し、異常時に保持するなら理由/再開条件を記録する。旧proof/source/root・shared cache・x86・Git stage/commit/push・version/公開/外部書込は禁止。全goal active・未達。
