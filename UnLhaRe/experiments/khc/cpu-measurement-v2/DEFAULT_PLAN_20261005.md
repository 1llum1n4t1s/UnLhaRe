# Default root検証の反復削減：失敗先行計画

2026-10-05。親がsrc/khc/block/mod.rs、新default probe、runner source-pinを所有する。既存dirty変更と旧EXE/reportを保持。基礎khc_block_adversarial（30故障/30回復）は変更前に成功した。

Performance根拠：852 rootを毎回local wireへserialize、parse_rootでdispatch確保、1024 CDF比較。root_defaultは選択Fitのroot split=falseかつfrequency==uniform(k)であるため、同じkのdefault間でwire/CDFは同一。Selectedのhigh反転もnosplit rootのlookup結果を変えない。k2/3/4各最初のdefaultだけ通常のwire/CDF検査を行い、そのblock内の以後defaultを共有する。nondefaultの全検査とpacket default/objective=0の整合チェックは毎回維持する。既定値を推測したりuniformかつsplit=trueをdefaultとしてはならない。

失敗候補：default識別誤り、k3余り分配差、選択low/high差、k別状態混線、packet費用/順序、frame変化、上限計算、decoder悪性入力拒否。初回3CDFとnondefaultは元の検査を残し、旧leaf EXE対新EXEで7種入力×warmup1＋9、全frame byte一致/自己/相互復号を検証する。Paid採用後Lowの確認と固定3block/破損/最大分割の回帰も残す。新unit testを書かない。

採用：全byte互換・回帰成功・実入力の圧縮中央値で改善またはno-regressionを確認、64MiB ceiling内。7-Zip完成ゲートは変更しない。Stats.root_cdfsは実比較回数であり参照は製品module内だけとrgで確認、通常の852 root出力は維持する。追加cacheは3boolだけ。元のparse容量max計上を維持し、資源容量を過少にしない。

opop6観点：Performance採用検証、Hardeningは上記境界、Testerは全frame比較。Cleanerは同じ反復削減へ統合。Modernizer/Normalizerは現行private APIが最適で独立変更不要。Asyncは既存資源寿命を維持、Startup/Intelは今回非該当。親が全観点を担当、外部照会なし。

予算：Cargo追加204953438 B/256MiB、残り63482018 B、新target48MiB以内を予約。専用report8MiB/256KiB、raw/frame disk保存0、free5GiB、child64MiB/60s、suite900s。nativeとbuildを重ねない。新依存/version/Git/公開/削除なし。
