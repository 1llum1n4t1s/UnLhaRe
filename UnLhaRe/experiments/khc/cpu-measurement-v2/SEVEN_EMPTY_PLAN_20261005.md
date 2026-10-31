# 現在KHC版対7-Zip：全development再評価

2026-10-05。公式https://www.7-zip.org/で現行26.03（2026-09-03）を再確認。既存7za SHA256 EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0、現在KHC empty probe D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79Eを使い、新build/downloadはしない。

SEVEN_ZIP_PLANの全16fixtureを変更しない。5synthetic＋Canterbury全11file全文、入力SHA/size/sourceをpin。0..4、5..10、11..15の3区間を逐次実行し、失敗時はその区間から先を起動しない。合計640 native calls、320自己往復を予定。各入力warmup1＋9 paired、元のfiで交互順序を決める。測定範囲を縮小/恣意選択せず、未完了区間があれば全体比較を未完了と報告する。

KHC paid independent block対7-Zip LZMA2/XZ、mx9/mmt1/md4m/mfb273。最大入力1MiB以下を4MiB辞書で覆う。全argvはreportへ保存。全header/model/checksum/終端を総サイズへ含める。process起動＋binary I/O込みmedian/min/maxであり純codec CPU/solid batchの測定ではない。private最終短命peak取り逃しの可能性も記録する。

失敗先行：区間の穴/重複、selected indexとsummary raw bytesの不整合、source/tool drift、別形式crossdecodeの誤実行、RAM/時間超過。各reportのrange/input/sample/counter/pinを照合し、全16 indexを一度ずつ集計する。crossdecodeは別形式なので0件。CPUquiet15%、child64MiB/60s、各suite900sを維持する。nativeとbuildを重ねず、他作業を操作しない。

GOAL_GATEの率優先/速度優先基準は不変。Canterburyは既知developmentで、未見/既圧縮・暗号化/solid/archive/Zstd再評価の代わりにはしない。現在版の全11file集計を新たに示し、旧leaf reportの速度倍率を転用しない。

容量：3unused専用dir、各8MiB/report256KiB、生raw/frame disk0、free5GiB。共有Cargo元baselineから追加211794073 B/256MiBは増やさない。削除/Git/公開/version/新依存なし。

opopは今回benchmark範囲を親が担当。Performance/Testerは全体差と統計・カウンタ検証、Hardening/Asyncは既存guards/プロセス解放維持、Modernizer/Normalizer/Cleanerは追加変更不要、Startupは起動込みと明記、Intelは公式版確認。基礎検証は現在版の既存3 E2E/clippy成功とpinを再利用し、追加source変更はしない。
