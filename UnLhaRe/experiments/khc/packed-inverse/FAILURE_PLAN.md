# packed inverse：コード前の失敗契約

親PACKED_INVERSE_PLAN初稿SHA82087A3025E22B3B0BE22FC577CB7EB124CA3A6186DD63A733C48863E6801782を読み、計時内scratch free/計時外result dropの区別追記後の最終SHA65E24089DC8F0C825029CE1B2CDB0BE7A1BBBBCBAA2829EFECFF64159514FF5Dを再読して固定した一設定。既存codec/model/wire/frameや製品は変更しない。ststの正常/境界/type/resource契約をこのbounded standalone E2Eだけに適用する。既存coverageは前診断のreference codec E2Eであり今回candidateは未検証、基礎検証は同EXE reference比較へ限定する。追加委任・unit tests・全製品suite・同条件再試行はしない。

| 分類 / ID | 事前固定したfixtureと期待結果（失敗時HIGH） |
| --- | --- |
| happy H0..H8 | empty、[0]、[255]、[0,255,0,255,1,254]、0..255全byte列、4096個7、4096個0/255交互、4096個 `(i*73+19)%256`、4096個xorshift32 seed0x12345678低byte。凍結BWTを各一回、reference/packed全plainを元RAM inputへ直接比較 |
| type T0..T8 | empty last/primary0、last[0] primary1、last[1,0] primary0、last[1,1] primary0、last[0,0] primary0、last[257,0] primary1、last[1,0] alphabet[0]、同alphabet[0,1,2]、last[0] alphabet[]。両inverse本体がErr、成功値捏造/内部panic不可 |
| state T9..T10 | 短LF cycle [0,1,1,1] primary0 / [1,0,1,1] primary1、alphabet[0,1]を両本体でErr。n unique visitsと終端primary確認を維持 |
| wrapper W0..W2 | last[0] alphabet[257]と[u16::MAX]、private MAX_N+1=8388610のRAM u16列は共通wrapperで先にErr。参照bodyのalphabet前提/最大長を保ち、この3拒否を旧内部guardの成功とは呼ばない。MAX_N+1は親担当が追加した独立scopeで固定input/BWT/timing前に解放する |
| boundary B0..B2 | n=8388607/8388608/8388609、lastを全1、最後0、primary=n-1、alphabet[0,1]。forward巨大BWTなし、reference/candidate全bytes一致かつ全0、route packed/packed/fallback。別の巨大期待plain Vecなし |
| bits P0.. | index0/MAX(0x7fffff)、byte0/255、flag0/1の全8組で非重複/lossless unpack、index8388608拒否、mark二回拒否。checked next<nをwalkerで検査 |
| pins/limits | 凍結codec関数全文allowlist/pubだけ、oldroot/tool/input/plan/causal成功reportのbeforeafter SHA/bytes/UTC一致、output未使用、source<=300KiB、EXE<=1MiB、report<=256KiB、stdout<=64KiB/stderr<=16KiB、compile<=60s/native<=120s、owned process0 |

正常系happy.rsと拒否系adversarial.rsを分け、同一bounded入口で実行。この2fileは初稿保存後にworkerが編集停止し親へ所有権移管、親がmetadataとMAX_N+1 wrapper caseを完成させた。workerは両file読み取り統合のみ、compile/nativeは全source準備完了・編集停止後に親が一回実行する。小handは固定timing前、巨大boundaryは後、各caseは破棄して次へ。concurrency/chaosはAPI・共有state・network/時刻操作なしのため非該当。resourceは事前容量式＋最終実容量/timeout/peak読取、typeはraw last/alphabet前提へ限定し一般protocol fuzzは非該当。

## packingとreference抽出

bits0..22=LF next、23..30=last symbol-1、31=visited。sentinelは検査済みprimaryのみdummybyte0。counts/sentinel1/alphabet presence、n訪問unique、最後primaryを保持。step0はsentinel、step>0はresult[n-1-step]へ直接byte。n<=8388608はpacked、n=8388609は元usize fallback、wrapper max plain8MiBを維持。raw alphabet>256は共通wrapperだけで拒否。reference.rsはtype Result aliasと抽出2関数以外を置かず、visibility追加以外元function bytes完全一致。正確なoffset/length/SHAはreference-ledger.jsonに保存し、実行前とreadonly verifierで全文再構成比較する。

## RAM最悪推定と計時境界

x64 reference本体作業=LF8n+visited n+text2n+result(n-1)=12n-1B、packed=4n+result(n-1)=5n-1B。referenceはcapacityを返さないためlogical式、candidateはallocation直後capacityを読み取り別報告する。巨大case最大はlast2n＋保持reference結果(n-1)＋fallback参照作業(12n-1)＋4MiB余裕=15n-2+4194304=130023437B（n8388609）。固定timing最大を保守的にinput(n-1)+last2n+保持result(n-1)+参照作業(12n-1)+4MiB=16n-3+4194304=49170413B（n2811007）。固定fixtureはboundary前にdropする。BWT別phaseは凍結SA-ISの50*2811007+1MiB=141598926B推定。全phase160MiB=167772160B以内。logical/allocator推定で強制quota/実peak保証ではない。

Windows PROCESS_MEMORY_COUNTERS_EXはrepr(C)、x64 size80/offset検査後K32GetProcessMemoryInfoをnative終端に計時外一回だけ呼ぶ。失敗は未測定、成功peak>160MiBは資源未達として隠さず保存する。外部依存/常駐processは作らない。2026-10-04親がMicrosoft一次資料のBOOL/HANDLE/DWORD ABI、EX受理とKernel32 exportを確認した：[API](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)、[EX struct](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex)。PeakWorkingSetSizeはprocess物理working-set peak、PeakPagefileUsageはprivate commit peakで、phase別peak/実pagefile上bytesではない。実size/offsetをnativeで検査し、API失敗を0測定にしない。

fixed同EXE各warmup1＋9pair：pair偶数reference→packed、奇数packed→reference、比較/集計/JSONは計時外。timerはfunction呼出前から戻り直後、内部配列allocate/init/guard/walk/freeを含む。戻りresult Vecのcaller側dropは全plain比較後・計時外で、余分なcopyなし。raw18samples、medianと順別sampleを保存、CPU quiet未確認なので限定診断で正式速度/全decode gateと呼ばない。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE（cfg frame_audit/primitive_audit）、一compile/native。一回失敗は保存して親判断へ返し、設定sweep/有利再試行/追加wrapper拡大なし。8MiB全出力、RAM/input/frame/plain/rawtrace diskcopyなし、Cargo/PDB/Git/外部write/版/依存/製品/x86/削除なし。最終RESULTとreadonly verifier、report保存後guard/process0、編集停止/ownership返却まで完了する。別新context独立監査は未実施。
