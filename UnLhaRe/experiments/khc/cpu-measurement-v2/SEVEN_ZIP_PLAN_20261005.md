# 更新版対7-Zip：事前固定のdevelopment診断

2026-10-05。公式https://www.7-zip.org/で現行安定版26.03（2026-09-03）を再確認し、既存x64 7za iでも26.03を確認した。新ダウンロード/ビルドなし。SHAは7za EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0、KHC leaf版 A92088A87879B4328EA61179BCAD7BAB741D1BE2CB9DACE1598C523FBE2F234D。

入力を評価前に固定：既存CORPUS_MANIFEST.jsonのcanterbury-development全11fileを全文、加えてempty/1B/repeat4KiB/all256×8/seeded random64KiB。最大1MiB以下。全SHAとsourceをpinする。Canterburyは既知developmentであり未見と呼ばない。入力種類は文章/HTML/ソース/表計算/bit画像/binary。既圧縮・暗号化入力、未見セット、solid/archive費用、Zstd/現行方式の再測定は後続評価に残り、本診断で完成としない。

方式/条件：KHC1 default paid（単一worker、独立block）対7-Zip26.03 LZMA2/XZ、`a -an -txz -si -so -m0=LZMA2 -mmt1 -mx9 -md4m -mfb273 -bd -bso0 -bsp0`、復号`e -an -txz -si -so -bd -bso0 -bsp0`。mx9、長いmatch探索fb273を固定し、4MiB辞書は最大入力1MiBより大きく全入力距離を覆う。64MiB WS/private上限であり、実消費RAMは別々に報告する。これは設定空間全体の最適を保証するものではない。大きいsolid入力での辞書制限と混同しない。

共通progress-driven pipeline、warmup1＋9 paired、順番交互、process起動・binary I/O込みのmedian/min/max。各方式自己復号で元byte完全一致。別形式のためcross-decodeは非該当で実行しない。両方のheader/checksum/model/終端を含め総frameサイズを報告する。KHC側の形式費用を除かない。stdout1MiB＋4096、stderr16KiB、child64MiB/60s、suite900s、CPUquiet15%を維持する。native計測中にcompileしない。

失敗候補：CLI args不受理、空stream、stdout混入、別形式crossdecode誤実行、count契約不整合、source drift、RAM/時間超過。argsをreportへ保存、最初のempty warmupを実経路capability確認とする。各Read/Write完了のprogress時のみsleepを省き、外周ごとに全guardを維持する。Native expectedは16fixture×10round×2方式×2calls=640。採用・完成の基準は既存GOAL_GATE_20261005を変更せず使用する。勝敗をfile別/全development別に出し、syntheticだけの勝利で総合優位としない。

出力unused専用dirのreportのみ最大256KiB/予算8MiB、raw/frame disk保存0、free5GiB。共有Cargo累計追加204953438 B/256MiBは増やさない。新依存/Git/外部書込み/公開/削除なし。親がrunnerと今回のplan/resultを所有。既存reportは保持し再記述しない。
