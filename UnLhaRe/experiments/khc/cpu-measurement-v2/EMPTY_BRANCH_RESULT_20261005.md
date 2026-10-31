# 空頻度枝：byte互換と限定的な圧縮時間改善

2026-10-05 Windows x64。EMPTY_BRANCH_PLANの候補を採用。ゼロ親を見ただけでは省略せず、全子孫のゼロを検査してから従来uniform/leafで非分割を選ぶ。非空枝・decoder・形式revision・CDF・CRC・stored判定は不変。追加allocationなし。未訪問子Nodeはlookup/writerから非分割leafを越えて参照されない。

## 検証範囲と計数

Paid初回はCPUquiet待ちでsuite900秒を超え失敗した。そのreport全体を成功へ変更していない。完了済fixture0..3の各warmup1＋9と、新rest reportのfixture4..6の各warmup1＋9を参照し、初回の部分fixture4を分析から除外した。両reportのKHC source/helper pinを照合して差0。入力番号・順序・9測定・CPUquiet15%・64MiB/60sは不変。Lowも0..3/4..6の別runで全7入力を完了した。

各modeの採用分析は70組の全frame一致、140自己往復、14両方向相互復号、294 native calls相当の完了記録を覆う。実際に実行したcallsはPaid312（うち初回部分fixture4の18callsを除外）、Low294、計606。選択した完了記録の合計は588calls相当。部分測定を重複加算しない。全runのsource/input/tool live pinは各終端時に一致。runnerは分割対応で変わったが、codec sourceとEXEは変えていない。

| 入力 | Paid圧縮中央値 旧→新 ms | Low圧縮中央値 旧→新 ms |
| --- | --- | --- |
| repeat4KiB | 106.022→109.169 | 101.432→106.875 |
| all256×8 | 117.789→98.106 | 101.271→101.084 |
| random64KiB | 394.454→315.651 | 308.761→260.188 |
| alice29 | 280.202→232.323 | 235.374→213.988 |
| kennedy | 758.441→619.110 | 640.541→577.620 |

Paid random/alice/kennedyとLow kennedyは旧新min/max範囲も分離した。Paid alice約17%、kennedy約18%、Low kennedy約10%の圧縮中央値短縮で、候補を採用する根拠とする。tiny/repeatを含め全入力の優位を主張しない。repeatの中央値悪化は範囲内変動で確定的な回帰とは言わない。低頻度・少量入力では効果が小さい。

復号処理は変更していない。Paid alice復号137.950→142.253ms、kennedy297.852→303.028ms、Low alice140.117→140.573ms、kennedy303.998→301.810ms等の変動もraw sampleに保存。時間はprocess起動＋binary I/O込みで純codec CPUではない。圧縮サイズは全byte一致のため不変。最大RAMは全childで64MiB以下。

## 回帰と限界

前ターンの現行codec sourceで既存3 E2E成功：固定3block156483/237176/119861 B、完全復元、30故障/30回復、最大split。成果物block-normal-44916、block-adverse-22244、model-boundary-388はbuild/khc-product-e2e-20261005配下。lib＋empty example clippy -D warnings、2Rust rustfmt check成功。以後のcodec sourceは測定pinで保持し、変更はrunner/docsのみ。

内部malformed Histの直接注入は未実施。公的入力からHistは非負・tail/CAPを確認したbundle経路で生成され、今回も全空子孫の検査を維持する。全repo/container/非Windows nativeはこの候補で再実行していない。

## 再現と成果物

新empty probe SHA256 D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79E、旧fill probe 3F9E8ABA9500D0DF085A49DB071DBAF09DE3FE8FE4BB25C2C9263EB13FD2F63F。run.ps1へ両EXE/SHA、HistoryMode paid/lowを渡す。全件は既定、分割ならFirstFixture0/LastFixture3とFirstFixture4/LastFixture6を別の未使用Attemptで実行する。AllowDifferentFramesは付けない。

- Paid初回失敗：empty-paid/report.json、16464 B、SHA256 6C51CCA5CA1B7BA8119A2CD7F6E8A3C6895FA4A8CFAB084F2CBFB4C95157F5B7。
- Paid rest：empty-paid-rest/report.json、15910 B、SHA256 7596893F207C5F95951C8BED802E6D95C29AD0D850045EF6CD2288BE7EF50DCF。
- Low head：empty-low-head/report.json、17544 B、SHA256 8141563EE4987C256708920FECC61C53EF2407864679956408FDD573E3B417B7。
- Low rest：empty-low-rest/report.json、15882 B、SHA256 5BDCDF8A61BEE327144ACF1D0F6CBA8364835DE293A8C68649F27FFEDA17AD78。

各パスはbuild/khc-cpu-measurement-v2-20261005-で始まる専用dir。4report合計65800 B、raw/frame disk0、新compileなし。共有Cargo元baselineからの追加211794073 B/256MiB、残り56641383 B。削除/Git/公開/新依存なし。

opop全観点はEMPTY_BRANCH_PLANに従い親が担当。Performance採用、Hardening/Testerはbyte互換/回帰成功、Normalizer/Modernizer独立変更不要、Cleaner同原因に統合、Async寿命不変、Startup/Intel今回非該当。追加の読み取り専用analystは次のdecoder候補を返し、DECODE_CANDIDATESへ記録した。

GOAL active。7-Zip総合優位は未達。旧leaf版の全11file比較を最新速度に読み替えない。次は現在版の全development再評価で差の残る箇所を確認し、decoderのactive prefix移動またはForest固定コピー削減を反証付きで検証する。率の弱点と未見評価も残り、局所速度だけで完成としない。
