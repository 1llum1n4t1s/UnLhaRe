# 非活動クラス最適化：失敗先行計画

製品encodeのDenseは成功したrecordでだけ加算される。クラスの3072行がすべてゼロなら、low/high Histもゼロで、Fit loss=0・root objective=0・split不採用、tieはlowを選ぶ。ゼロHistのFitをblock内で一度だけ遅延構築し再利用する。非ゼロuniform頻度をゼロクラスと混同しないため、Denseの全値を直接判定する。activity推定や新wireの手書き実装は採用しない。

失敗候補：class/shape誤判定、k=3のuniform丸め差、low/high選択差、root順序差、同時生存cacheの容量計上漏れ、全入力storedへの誤fallback。既存Selected/root_wire/parse/CDF照合/appendを維持し、cache＋active Fit容量を計上する。ゼロingestは全6階層へ0を加算するだけとbundle.rsで確認した。

検証：旧CRCのみhelper（CEA86D9E...、今回再構築しない）対新候補helperの全frame一致、自己/相互復号、PaidとLowHistoryOnly。新unit testは追加せず公開API E2Eを使用。既存30故障/回復と境界E2E、lib clippyを再実行。旧報告は保持。runnerは既存progress pumpを用い、7種入力・warmup1＋9測定、child64MiB/60s、suite900s/report256KiB、raw/frame disk保存0。固定3blockは既存境界E2Eで別途確認し、旧新全frame比較の対象外であることを報告する。

予算：共有Cargo累計追加199589051 B、元baseline5906793080 B、上限256MiBを変更しない。今回追加ビルド48MiB以内を予約し、出力各8MiB、空き5GiBを維持する。削除・外部公開・Git・新依存・version変更なし。

opop基本6観点：Performanceは反復Fit構築削減を採用。Hardeningは全値ゼロ判定と容量計上を採用。Testerは上記公開API差分検証を採用。Cleanerは同原因の共通root処理に統合。Modernizer/Normalizerは現在のprivate APIで足りるため独立変更なし。同期codecのAsync/Startup/Intelは今回非該当。速度倍率は計測前に断定せず、符号列差・上限超過時は原因を切り分ける。7-Zipへの優位判定は別の事前固定ゲートであり、今回の局所高速化だけでは完了しない。
