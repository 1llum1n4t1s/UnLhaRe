# 完全key context：コード前の固定失敗契約

DIRECT_EXACT_CONTEXT_PLAN SHA3D97697B14CB26E2C315AA644A0BB05F8857C2FD8FA65159D78CC48918DAF372、QUESTION SHA02C1BC5A16744ECA7C787C14C3C2BC9AD4909F531F52E094970C3CD4EC79F90C、BUDGET SHAC58C7F722B1218D6C6C9E1042EA54854B171310E0ADC8C5801A8645A28A7ABB1を全文読了。元causal prior1/+2/rescale閾値32768、4expert、feature/history/grammar、weight255/256+1/1024、f64/Q32768累積policyは保持する。変更はu16 Fenwick nodeとrecent/joint完全key辞書だけ。一設定loss screenで実frame/速度/総合到達の成功としない。

| 分類 | 実装前の失敗条件 / 親E2E期待 |
| --- | --- |
| u16 Table | 非負部分和<=total<32768を破る切詰め/overflow、rescale前predictを変える、leaf/node/total/prefix差。3rowsを旧u32とdenseで初期・全16256更新後全258prefix比較、rescale1/max_total32767/terminal771。query/observe範囲拒否でleaf/tree/total不変、checked node add/u32 queryを維持 |
| ExactMap | cap4/slot8、hash同slot keys[0,1,18,21]を別row0..3へ登録、同keyは同row、満杯後43とu32MAXをErr。prepareは全keys/rows/used/capacity不変、commitは使用数とslot/keyを再確認して自然stale予約を拒否。find未登録None、第二mapへ同順登録後全配列一致。bounded linear probe/empty key-row整合 |
| Mix | 正常pool1/1で全CDF524/actual interval正支持とQ端点、4bank更新、旧p posterior4/weight和。拒否pool recent2/joint1でrecentには空きがあるのにjoint満杯の新key(symbol2/recent1)を拒否し、先行部分登録を反証する。全key/limit/weights/両map容量・予約を先にpreflight。満杯1/token3/key4/weights6/非一様seedでweightsが変わった自然stale1。全bank leaf/tree/total/first_key/map/active_rows、weights bits/observationsを親が直接比較、読取opsは論理stateと区別する。stationary weights再利用まで拒否する普遍的stale保証ではない |
| terminal | 全114720row leaf/node direct sum、全map slot/key→row/row登録key一致、used/occupied slots/full first_keyを照合。unused rowはinitial prior、alias row fallbackなし。全更新毎の固定input dense oracleとは呼ばない |
| pins/resource | 元causal graph/旧u32基礎参照/新source/tool/input/plan/question/budget/旧report pins前後不変。compile60s/native120s/source300KiB/EXE1MiB/report256KiB/streams64KiB16KiB/output8MiB/160MiB peak/owned process0。初回失敗保存、設定sweep/追加実行なし |

親はhappy.rs/adversarial.rsの設計・編集・実行担当、workerは両file編集禁止。parent happy::fenwick()/adversarial::fenwick()はJSONを返す、辞書/mixtureの小E2E公開署名は親へ通知して固定。旧e2eの大model成功を新dictionary成功へ転用しない。新unit testsなし。全source停止ready後、親だけが一compile/nativeと事後readonly verifierを実行する。

## 公開private APIとtransactionの範囲

ExactMap::new(cap)->Result<Self>、prepare(&self,key)->Result<Plan>、commit(&mut self,plan)->Result<usize>、find(&self,key)->Result<Option<usize>>。pub keys/rows:Vec<u32>、used/capacity:usize。slots=2*cap、empty=u32MAX、wrapping hashは元と同じ、linear probingをslot数でbound、rowは初登録順。PlanはCopy/Cloneで内部fields private、予約時used/slot/key/rowを含む。validate_plan(&self,&Plan)は変更なしでcommit可否を調べ、Mixが両mapの全preflightを完了できる。満杯は明示Limit、別keyを同rowへ混ぜない。

Table公開rows/leaf(Vec<u16>)/tree(Vec<u16>)/total(Vec<u32>)/ops、new/count/prefix/observe/verify_all/allocation_bytesは旧署名。Mix公開banks/weights/observations、new()とnew_with_pool_rows(recent,joint)。Bank公開table/family/first_key(Vec<u32>)/map(Option<ExactMap>)/active_rows(u64)。Prediction公開fieldsは旧keys/rows/global/token/limit/probabilities/old_weights/mixture_probability/low/highでClone可能。map新登録はpredict時、table counts/weights/observationsはobserve時。first_keyは登録済rowの対応を保持し、direct bankもpredict preflight後に登録する。故意にpub内部全stateを破壊した全エラーrollbackや任意interleaving APIを新保証しない。

## 正確な配列RAM式

rows32+16384+65536+32768=114720、leaf257*u16/tree258*u16/total*u32=1034B/row、計118620480B。2倍辞書slot key/row各u32で1572864B、first_key全rows*u32=458880B、heap model120652224B。weights1024Bを含むinline Mix/Bank/Table/ExactMap descriptor/countersはsize_of::<Mix>()実値を追加し、実行前上限4096Bを固定（結果へ実値/各Vec capacityを記録）。fixed mix最悪=120652224+4096+run1048576*12+input2811006+frontend余裕1369112+allocator4MiB=141613654B <160MiB167772160B。親budget141609558Bに小inline実値を追加しただけ、pool/prior/settingsの変更なし。

BWTは別phase141598926B推定、完了後mixだけ構築し重ねない。小E2E終了後model/mapをdropして固定phaseへ。小Mixもglobal/symbol固定rowsだが大model二重保持なし、Map二個cap4は小scope。logical/allocator推定をquota/実peak保証と混同しない。凍結WinAPI80B helperでnative終端計時外一回peakWS/privatecommit、失敗未測定、peakWS>160MiBはresource-unmetとして保持し緩和しない。

固定input2811006B SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一read/BWT/Front walk。rank/length各889227、run889227、escape742、history1778454、grammar0x58735a2b7383d755を維持。quantized/unquantized/expert lossをKahan集計し、screen=ceil(Qbits/8)+3079、gate483599B。tables保存0/policy metadata未定の必要条件のみ、failならcoderや新設定へ進めない。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/cfg frame_audit+primitive_audit。新Cargo/PDB/rawtrace/input/frame/plain diskcopy、Git/外部write/削除/製品/wire/依存/版/x86/README公開変更/追加委任なし。最終RESULT/verifier/guard/process0、編集停止/ownership返却まで。別新context独立監査未実施、総合goal条件未達は保持する。
