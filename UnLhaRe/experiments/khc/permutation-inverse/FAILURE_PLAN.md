# read-only packed24 inverse：コード前の固定契約

親plan SHA87CEA1CAD262E31A0D163E9EDB53C996A62EC8D4E83EA29112FF97A014E4519C、question SHA06C7A91A04E20EA49CCE966DBB7BBBE21BECC38862C2A1731344E43137797FF1を全文読了。一設定だけ、全goalのsize483599B/encode574.5624ms/decode47.3884ms、CPU15%/同資源/holdout/category/完成書庫/API/4native条件を緩めない。inverse内部layoutだけの診断で全goal達成を主張しない。

## Failure-first / 事前固定fixture

| 分類 | 失敗条件とE2E期待（HIGH） |
| --- | --- |
| permutation proof | immutable lastのsymbol範囲/count和/checked prefix/rankからLFが[0,n)の置換であることを導出。外部nextを受け入れない。step>0の早期primaryを必ず拒否、n歩後primaryを必須。終端だけで約数長cycleを受理したら失敗 |
| happy9 | empty、[0]、[255]、[0,255,0,255,1,254]、全0..255、4096個7、4096個0/255交互、4096個(i*73+19)%256、4096個xorshift32 seed0x12345678。各凍結forward BWT後original/23/24全plainを元inputへ直接比較 |
| internal11 | empty last、primary>=n/非sentinel、sentinel0/複数、symbol257、alphabet不足/余分/空、短cycle [0,1,1,1]/primary0、[1,0,1,1]/primary1。original/23/24の拒否を比較 |
| wrapper3 | alphabet257/u16MAX、MAX_N+1=8388610の独立RAM u16列16777220Bを共通wrapperで拒否。旧body内部成功ではなく先行wrapper契約。固定BWT/timing前に解放 |
| exhaustive1793 / divisor3 | n1..8、sentinel位置全通り、他symbol1/2を全列挙。original/23/24で受理255/拒否1538と受理時全plain一致。LF独立置換導出とnative有限列挙を区別。internal11内cycle2 [1,0,1,1]/primary1に加え、独立cycle3固定hand n6 last[2,0,2,1,2,1]/primary1/alphabet[0,1,2]（LF[3,0,4,1,5,2]）を共通拒否、divisor_cycle3_rejections=1を別報告。模型/設定変更ではなく終端だけの約数cycle受理を反証する |
| bits | index0/0xffffff×byte0/255の4組lossless。index0x1000000の1拒否、巨大16MiB maskfixtureは作らない。candidate訪問済みwrite/bitなし |
| boundary3 | n8388607/8388608/8388609、全1/最後0/primary n-1/alphabet[0,1]。全output0かつoriginal/23/24全plain一致、candidateはすべてpacked24。originalと23比較後23結果をdropし24比較、巨大結果は最大2つ保持。case間全部drop、巨大forward/期待plain Vecなし |
| pins/limits | original/pub-only reference全文ledger、凍結23/source/tool/input/plan/question/report/verifier pins不変。source<=300KiB/EXE<=1MiB/report<=256KiB/streams64KiB16KiB、compile60s/native120s、全出力8MiB、process0。初回失敗保持、追加実行/設定sweepなし |

親がhappy.rs/adversarial.rsを設計・編集し、workerはその2fileを編集しない。公開fnはhappy::small()->Result<usize>（9）、happy::boundaries()->Result<String>（3record JSON）、adversarial::checks()->Result<String>（上記分類JSON）。workerはFAILURE_PLAN/packed/probe/runner/事後RESULT/verifierだけ。source編集停止ready後に親が一compile/nativeとreadonly verifierを実行、worker本人は起動しない。旧packed23全root/build、親plan/decision、他者dirtyを変更しない。

## LF置換とAPI

symbol count c_s、checked prefix a_s、immutable lastの各symbol occurrence rank0..c_s-1が、区間[a_s,a_s+c_s)を重複なく埋める。区間は[0,n)を分割するのでLFは置換。置換の開始primary軌道は一cycleで、primary以外を先に再訪しない。早期primary拒否＋n歩後primary帰還によりcycle長n/全訪問が含意される。visited bit/scan/mark random writeを省略しても、この構築前提と早期検査を省略しない。

API: INDEX_MASK=(1<<24)-1、pack(next:usize,byte:u8)->Result<u32>、inverse(last:&[u16],primary:usize,alphabet:&[u16])->Result<Output>。Outputはplain/route="packed24"/scratch_capacity_words/result_capacity。bits0..23=index、24..31=byte。sentinelのprimaryだけdummy0。common wrapperでprivate MAX_N8388609を維持、全許容長をpackedにし旧23fallback上限を変更しない（新24にはfallback不要）。checked starts/count/occurrence/range、primary/sentinel/alphabetとbyte0/255区別を維持。

## RAMと限定計時

固定同phase最大= input(n-1)+last2n+保持結果2(n-1)+reference作業(12n-1)+4MiB=17n-4+4194304=51981419B、n2811007。巨大caseは結果最大2つで15n-2+4MiB、最大n8388609で130023437B。BWT別phase141598926B推定、同時保持しない。24作業capacityは4n+(n-1)、reference scratchはbody非変更のためlogical12n-1。Vec capacityとlogical/allocator見積り、native process生涯実peakを区別し、160MiB=167772160B以内を維持する。

凍結Windows helper（repr(C) EX80B/cb80B/offset自己検査）で計時外終端に一回peakWS/privatecommitを読む。API失敗は未測定、peakWS超過は資源未達として保存し閾値を緩めない。

固定input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一read/BWT。同EXE各warmup1＋9round×3calls=27。round%3順はR→23→24、23→24→R、24→R→23固定。function scratch allocate/init/guard/walk/free・output構築は計時内、全plain比較/caller drop/集計は計時外。raw27/全中央値/ローテーション別中央値を保存、CPU quiet未確認は限定診断。旧23の49.6452msや前opt2値を今回効果へ転用しない。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/cfg frame_audit+primitive_audit。Cargo/PDB/rawtrace/input/frame/plain diskcopy/Git/製品/wire/依存/版/x86/外部write/削除/追加委任なし。別新context独立監査は未実施。最終RESULT/verifier/guard/process0、編集停止と全ownership返却まで完了する。
