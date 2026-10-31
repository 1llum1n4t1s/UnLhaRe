# 通常Model entropy lookup 候補の先行契約

対象はprivate hard-cut-model-lazy通常codec。旧float Math/pool/CTS更新順とwireを維持し、exp-scale候補と重ねない。製品、公開API、依存、version、Git、x86、外部更新なし。

## 失敗と数値

既存Model構築を先に完了し、その後でModel所有entropy表を生成。32769 f64 payload 262152 bytes、追加reserve失敗は明示的な新constructorエラー。既存constructor失敗の優先順は変えない。容量overflowの実try_reserve拒否は確認するがOS OOM注入済みとは主張しない。

全frequency 0..32768を旧式 `-(f64::from(f)/32768.0).log2()` とto_bits直接比較。0/+Inf、32768/-0、範囲外32769/u32::MAXは旧式fallback。Kahan入力順とCTS拒否前の非commitは不変。有限チェック前後の表全entryを独立にbit比較し、状態snapshotが表を含まないことを全state不変の根拠へ使わない。表は生成後mut accessor無し。

## 所有と差分

workerは新hard-cut-entropy-lut内のFAILURE_PLAN.md、entropy.rs、candidate_model.rs、candidate_codec.rs、control_scope.rs、candidate_scope.rs、probe.rs、run-native.ps1だけ所有。先行失敗計画を最初に保存。親が停止READY回収と全文差分確認をしてから実行する。元sourceは凍結。

候補Modelは所有Table field、既存Model構築成功後のTable生成、entropy add引数のTable lookupだけ。Model/CTS/poolの更新算術は変えない。codecは候補Model pathだけ変更、各scopeはそのcodecを結ぶ。ルートentropy moduleはcandidate Modelから参照。通常old Math/poolを直接参照。

## 一回の検証

compile1、native finite1/selfcontrol1/selfcandidate1/pair1。既存14正常/34破損/4短header JSON全文を維持。pairは全frame478856/両方向全plain2811006/各型Proof14 Eq/型間Debug14/全4stats/CRCを直接比較。input read1、encode/decode各版1、再encode0、旧plainを候補restore前に解放。

有限domain32769＋fallback2/同一Kahan列・表前後全bits・実capacityoverflow拒否をnative finiteに含める。短入力も旧E2Eで確認。計時は元API境界（constructor含む）、単回control先行/warm0の内部screenだけで正式速度ではない。

表actual capacityを測り、通常model/encoder/inverse boundへpayloadを追加（model・encoderには表1個、inverseは保守的に表1個加算）。全実OS峰値160MiB、source model32MiB/phase64MiBを維持。BWT boundは旧142647787 bytes。

compile60秒/native各120秒、出力EXE1MiB/report256KiB/全run8MiB、sourceと計画300KiB、空き5GiB以上。ASM、入力/frame/plainディスクコピー、生traceなし。旧report/source/hash/mtimeをbefore-after-live照合、既存共有helperの範囲検査/locks/bounded childを維持。未使用output限定。再試行・予算緩和なし。

## 観点と完了範囲

Performance: 3825340 log2/方向を32769初期化＋lookupへ置換する候補、時間は未測定。Normalizer: 同一float式と凍結kernel接続。Hardening: reserve/範囲外/非commit。Tester: finite先行と全wire E2E。Cleaner: 生コピー不要・証拠保持。Modernizer: 依存変更不要。Async: 旧plain先解放とlocks/finally。Startup: constructor費用を計時に含める。Intel: 外部仕様不要。

全正式gate（fullCLI encode574.5624ms/decode47.3884ms未満、archive483599 bytes以下、同memory/thread、quiet15%/warm1+9、holdout、4native）を緩めない。候補成功や内部時間だけでは7-Zip超え完了ではない。GOAL active、停止なし。
