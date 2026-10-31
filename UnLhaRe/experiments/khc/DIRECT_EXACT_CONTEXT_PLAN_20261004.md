# 完全一致context＋u16 Fenwick：コード前の一設定screen

前のpermutation inverseは凍結済みreport6D8CE7424756C440E286D8F9318FF80C544683F7ECDCC752D3A56B6FD55ACCDA。次はDIRECT_CONTEXT_ALIAS_QUESTION/BUDGETの構造候補だけを反証する。旧causal directのprior1/observe+2/rescale32768・4expert・重み更新255/256+1/1024・Q32768 cumulative規則を保持し、recent/jointのcount row混入を完全一致辞書でなくす。ゲート・混合係数・prior・精度・feature/grammarを変えない。

## 失敗一覧（コード前）

u16への切詰め/部分和overflow、rescale前後prefix差、正の支持欠落、辞書hash collisionを同rowへ混ぜる、同keyの登録不安定、誤key/満杯/古い予約で部分登録、encode/decode相当の登録順差、初期rowのcount不一致、Qの正区間/CDF順序破れ、terminal whole leaf/Fenwick/map照合漏れ、source/input/tools drift、実peak/出力/time超過、実frameでないlossを実圧縮率/速度/総合達成とする。

## 編集担当と基礎比較

新direct-exact-context/と未使用build/khc-direct-exact-context-20261004/だけ。workerはコード前FAILURE_PLAN、fenwick.rs/dictionary.rs/mixture.rs/probe.rs/run-native.ps1、事後RESULT/verifier。親はhappy.rs/adversarial.rsの設計・編集・実行とplan/decision。旧rootはread-only。追加委任/Git/製品/wire/依存/版/x86/外部write/削除なし。source準備ready/停止後、親が一compile/nativeを実行、担当本人は実行しない。

必要な基礎比較は凍結u32 Fenwickを同EXE referenceとして参照し、親テストで全prefix/leaf/total/rescaleを比較する。前causal direct検証も凍結証拠であり新dictionaryの成功を代替しない。private loss screenのみなので全製品Cargo suiteは非該当、新unitなし。ststの正常/異常/resource/stateカテゴリを親が所有する。

## 固定モデル/辞書

Tableは旧A257/stride258、leaf u16、tree u16、total u32。nodeは非負leafの部分和かつtotal<32768なのでnarrow表現可能。queryはu32 checked加算、rebuild/observeのnodeはchecked u16加算、初期/更新/rescale閾値・順序は元と同じ。

row数はglobal32/symbol16384/recent65536/joint32768。一様初期leaf1、unused rowも同じ。global/symbolは元直接index、recent/jointだけExactMapで分離。key u32/row u32の各2倍slot、empty u32MAX、old wrapping hash関数、線形probeはslot数以内、load最大1/2。使用済みrowを入れ替えない。row番号は新key登録順で0..cap-1。満杯・誤keyは明示Err、hash共有モデルや隠れた上限緩和へfallbackしない。

ExactMapのprepare(key)は変更なしで予約Planを返し、commit(plan)は使用数・slot/key一致を再確認して古い予約を拒否する。find(key)は完全key一致のlookup、未登録はNone。predictは全key/weights/limitを先に検査し、両辞書prepareと容量確認を完了してから登録をcommitする。満杯で一方だけ登録しない。dictionary登録はpredict時、counts/weights/historyはobserve時。stale Predictionは重みbitsを検査して更新前に拒否（旧契約）。内部データを故意に破壊した全エラーのrollbackを新公開APIとして保証するものではない。

公開private helper: ExactMap::new(cap), prepare/commit/find、pub keys/rows/used/capacity。Plan fieldはprivate可。Tableは旧new/count/prefix/observe/verify_all/allocation_bytesとpub rows/leaf/tree/total/opsを維持。Mix::new()は上記固定設定、new_with_pool_rows(recent,joint)は小容量E2Eだけ、pub banks/weights/observations。Bankのtable/first_keyとexact辞書状態は親が全state比較できるようアクセス可能にし、field名は実装前に親へ知らせる。

## 親E2E（コード前固定）

- Table3rows、全258prefixと旧u32/denseを初期および16256更新後に毎回比較。token先頭257回は全token、以後token2。rescale1と最大境界直前/直後、全leaf/total/終端nodeを照合。query/observeの範囲拒否はleaf/tree/total不変を全比較。
- cap4辞書でhash同slotの異なるkeyを固定して別rowへ登録、同key再登録は同row、4key満杯後新key拒否、empty key拒否、自然なstale予約拒否、find未登録None、全keys/rows/used不変を比較。同登録順の第二辞書と全文一致、入出力順を勝手に変えない。
- 小pool Mixで元four_keys/featuresを参照、全CDF prefix/intervalと正支持・total32768を検査、正常observe後4bank counts一致と重み和/stale拒否。recent/joint満杯で他bank/dictionary/count/weightsを変更しないことを全state比較。異常weights/key/limitは前の失敗契約を参考に親が確定。テストで大model二重保持を避け、E2E終了時に全部dropして固定phaseへ。

## 固定loss/資源/解釈

input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一read/BWT/Front walk。rank/length各889227/run889227/escape742/history1778454/grammar58735a2b7383d755の凍結条件を保持。quantized/unquantized/expert lossと正Q interval、終端全row/leaf/nodeとmap/key照合を保存。必要size screen=ceil(Qloss/8)+3079B（escape742/framing285/bitlength4/coder reserve2048）、gate483599B。これは実frame/復元・speed・最適下界ではない。failならcoderを作らず、prior/係数/容量sweepや同条件再実行もしない。

事前RAM model120652224B＋小weights1024B等を実配列一覧で追加し、fixed Front/input/余裕込およそ141.61MB、160MiBまで26.16MB。BWT別phase141598926B、混在させない。dictionary slots/keymap容量とVec実capacityを記録、全native終端に凍結80B WinAPI helperで一回peakWS/privatecommit読取。phase推定と実peakを分け、peak>160MiBはresource-unmetとして保存。全private入力の資源保証・満杯回避ではない。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/cfg frame_audit+primitive_audit。source閉包300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、全出力8MiB、空き最低5GiB。compile60s/native120s、一compile/native、失敗保持。Cargo/PDB/rawtrace/input/frame/plain diskcopyなし。before/after/live pins・過去report非変更・readonly verifier・所有process0・編集停止/ownership返却まで。総合goal固定size/encode/decode/CPU15%/同資源/holdout/category/完成書庫/API/4nativeは未達のままactive。
