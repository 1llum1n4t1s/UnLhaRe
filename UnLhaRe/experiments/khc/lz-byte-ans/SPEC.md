# private LZ byte CDF / rANS 候補

追加の失敗条件（再実行前）: backendの実capacityが予約targetより大きく、次の成長時の旧capacityが6MiBを超えるなら、18MiB予約だけでは同時生存を事前に保証できない。次のintervalより前にjournal満杯・旧capacityを検査し、この場合はErrで止める。通常capacityと非2冪capacityの境界を有限契約で確認する。これは実allocator故障注入ではない。

失敗を先に固定する: CDF 非単調・頻度0・端点逸脱、context 不正/リセット漏れ、number 0/log>20、距離0/過去外/長さ残量外、rep overlap、frame magic/revision/reserved/CRC/extent/末尾、range/ANS 非canonical終了、1MiB超、journal/output/実capacity上限、エラー後の独立呼出し。不利益とjournal/output limitだけ None とし、破損やallocation failureは Err。

費用: 外部/API/ダウンロード料金0、整数のみ。64MiB gate。借用raw/legacy/frame slice extent、旧context bitモデル、2132 u16新bitモデル、最大256*257*2=131584B CDF、復元raw、rANS retained12MiB/transient6MiBを再確保前から全額課金し、payload/frame Vecの同時生存と各実capacityを確認する。APIのsliceから背後Vecの余剰capacityは観測不能なので、親の測定でその分を加算する。各試行のStatsは観測可能なfeeと保守的journal上限を示す。

旧KHC1BLK rev2 method2/3の意味tokenのみ再利用し、match探索は変更しない。method2→ctx3、method3→ctx8。旧frameは40B、primary/model/alphabet=0、flags/reserved=0、wire/raw CRC、range全消費、復元byteのcaller raw一致を確認する。method0/1は構造/CRC検査後対象外None。raw<=1MiB。

新KAB1BLK\0 rev1は40B header。method0 stored/context0、method1 coded/context3or8、raw@12、modelbytes0@16、payload@20、rawCRC@24、wireCRC@28（0..28 + 32..end）、reserved32..40=0。codedは5<=payload<raw。encoderは旧payload-1を上限とし、同じheader込みで厳密に小さい時だけ返す。

CDFは257 u16、cdf[i]=128*i。byte s後、i=1..255のpart=cdf[i]-iを prefix(i<=s)でpart-=part>>5、suffixでpart+=(32512-part)>>5とする。端点0/32768固定、rate5固定、unsafe/SIMDなし。decodeは8回二分探索、consume1回。flag/rep/numberの旧整数prob更新と順序を保持する。

使い方: Rust harnessから #[path=".../codec.rs"] mod codec; で取り込み、encode_from_legacy(raw, legacy)、decode(frame)、finite_contract()、finite_legacy_contract(raw, legacy)を呼ぶ。非利益の実LZ fixtureは finite_nonbenefit_contract(raw, legacy) に渡す（適用外method0/1を非利益扱いしない）。backendは ../mdl-rans/entropy.rs、legacy decoderは ../../../src/khc/block/multi_range.rs をread-only参照。依存不要。#[test]は追加しない。親がrustc/build、有限契約入口、実fixture、full fee/速度/最新7zip比較を実施する。本担当はソースと静的確認のみでCodec完成/優位は主張しない。

Stats: caller_slice_fee は借用sliceのextent、library_capacity_bound はモデル/output/journalの最大library fee、peak_capacity_bound はその和。caller の余剰予約はdriverが別記してpeakへ加算する。journal_capacity/transient は実backend値、事前gateはMAX_LIVE_BYTESを全額含む。NoneではStats/frameを公開しない。finite_contractは ContractReport { checks, contexts } を返す。異常allocationの実注入、非利益fixture、1MiB実負荷・実process peakは親driverで行う。
