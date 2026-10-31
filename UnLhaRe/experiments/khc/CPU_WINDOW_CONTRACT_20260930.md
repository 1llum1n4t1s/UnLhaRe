# CPU静穏観測windowの反証 — fresh / gogo契約

対象P1: 現quiet-host.ps1の各child直後のformatted WMI CPUが、完了した測定対象自身を含む不透明windowであり、背景負荷の静穏判定を誤って拒否し得る、という仮説。出所はSAIS warmup完了後17%拒否（performance SHA C872E67E0199C46741EEFDAECDF879EF74E7FBA60CF332AB09A47505435FA3E1）。その1観測だけでは外部負荷か自身の残留か未判定。処方候補は閾値を上げる/目標を緩めるのでなく、開始終了時刻が既知で子処理と重ならない1秒のraw CPU差分へ将来のguardを差し替えること。検証前には既存observer/compare/contract/reportを変更しない。

対象の開始値: Windows10.0.26300 x64、PowerShell7.6.5、Ryzen5 7640HS 6core/12logical、Rust1.98.1。quiet helperはGet-CimInstance Win32_PerfFormattedData_PerfOS_Processor Name=_Total、preflight5/子前後15%上限。fixed gateは全archive<=483599B、strict encode<574.5624ms、固定group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、native26.03/options/thread1を維持する。診断値は通常性能・paired中央値・goal達成へ使わない。

## 外部仕様と数学

Microsoft公式GetSystemTimes（https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes 、更新2025-08-15/確認2026-09-30）ではkernel時間にidleを含み、64logical以下では全processorの合計。正のdelta(kernel+user)をtotal、delta idleをidleとして `100*(total-idle)/total` を計算できる。64超ではprocessor group境界があるので今回のobserverは拒否する。performance counterのformatted値は複数sample/windowによる（https://learn.microsoft.com/en-us/windows/win32/perfctrs/collecting-performance-data 、更新2025-07-14/確認2026-09-30）。公式仕様をそのままローカルの17%原因と断定しない。

## 診断前の失敗と所有範囲

新cpu-window/{native-times.cs,diagnose.ps1,将来採用時だけobserver.ps1/verify.ps1/compare-*.ps1}、新build/khc-cpu-window-20260930/、本契約/開発記録を所有。既存source/proof/binary/observerは凍結、Git stage/commit/push/version/deps/公開/他process停止/priority/affinity/power/cache変更なし、UnLha32Re/registry/旧policy拒否対象へ操作しない。比例数値の各cast/ulong加算・減算はchecked、native失敗/CPU数>64/0/後退counter/zero total/idle>total/非finite/0..100外/window<1000ms/子とwindow重複を拒否する。PInvokeは正規Kernel32 GetSystemTimesだけを読み取り使用、FILETIMEはuint low/high・ulong結合、SetLastError true。不正値をclampしない。

診断は固定SAIS candidate（SHA9AC5CA8F200611454F2AC7E482737518FA90842353F26B750F3A0420E07E7FBA）を最大3回、逐次別processencodeし、全frame483468B/B4F17...を照合。各child前に既存CIMと独立1秒rawwindowを記録、childのlaunch直前/終了stdoutstderr回収直後rawを取得、終了後に旧CIM→1秒rawwindow→旧CIMの順で記録する。前後windowと実CPU/壁時間を分け、during totalに対するchildCPU比とbackground残差は計測境界/丸め差を持つ診断でしかない。外部CPUが変動することを限界とし、false拒否が観測できなければローカル再現は未判定。試行3回を超えるblind retryや閾値調整はしない。timeout120s/自身のchildのみfinally解放、既存work/output上書きなし、祖先nonreparse/currentbinary/source/group SHA/長さをlockし前後照合。失敗も証拠reportを残す。

問題と処方は別判定。成立時だけ同因検索（quiet helper参照のlog-table/signed/SAIS/float比較）を必要/不要/未判定へ分ける。凍結済み旧compareは通常経路から外す将来入口を新規に作り、用途/新入口を文書で明記する。新observerならsame15%・preflight5・子前後各1秒、sample全て記録、busy一度でも拒否、counter/API異常拒否、計測壁時間外、codec中負荷spikeの厳密検出保証なしを維持。oldfailed証拠を成功へ読み替えない。

採用時のE2Eは実observer CLI＋実Native時間、raw数学の独立BigInteger照合、boundary15/15超/不正counter拒否、quiet前後window非重複、全39実CLI・前後source/proof/current identity・全frameを別担当で確認する。新unitなし。全goalは総合7-Zip超過で、guard修正/サイズ同値/単一corpus改善を完了へ縮めない。成果物は再現可能な入力/report/source/exe pinsを保持、独立照合後同一backend不要反復だけ安全に清掃。
