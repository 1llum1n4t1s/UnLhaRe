# 現在版対7-Zip：全development未達の実測

2026-10-05 Windows x64。SEVEN_EMPTY_PLANの全16入力を0..4/5..10/11..15の3区間で完了。入力index0..15を重複・欠落なしで照合し、計640 native calls、320自己往復、元byte完全一致、各report全live pin前後一致、crossdecode0件（別形式）を確認した。現在版empty EXEで測定し、旧leaf速度値を転用していない。

公式https://www.7-zip.org/で現行26.03（2026-09-03）を確認。比較はLZMA2/XZ mx9/mmt1/md4m/mfb273、KHC paidの独立block。最大入力1MiB以下を辞書4MiBで覆い、両方式64MiB WS/private上限で測定。全argv/version/tool SHA/source/input pinはplan/reportへ保存。全設定空間や7-Zipの他方式の最適を証明した比較ではない。

## Canterbury全11file

原文2810784 B。全header/model/checksum/終端を総サイズへ含める。時間は各fileの9測定中央値の合計で、solid/archive batchの中央値ではなく、process起動＋binary I/O込み。privateは短命最終peakを取り逃す可能性を明記する。

| 指標 | 7-Zip | 現在KHC |
| --- | --- | --- |
| 総圧縮物 B | 492380 | 494786 |
| 圧縮中央値合計 ms | 1351.978 | 3044.662 |
| 復号中央値合計 ms | 1085.989 | 1568.100 |
| 最大kernel peak WS B | 31973376 | 27885568 |
| 最大観測private B | 57802752 | 25436160 |

総サイズ1.004886倍（0.49%大きい）、圧縮時間2.252006倍、復号時間1.443937倍。メモリ優位だけではGOAL_GATEを満たさない。旧leaf診断の倍率と並べることはできるが、別時刻の別runなので、その差を独立したpaired Before/After実測と主張しない。局所改善の効果はEMPTY_BRANCH_RESULT等の旧新paired検証で示している。

| file | 7-Zip B | KHC B |
| --- | --- | --- |
| alice29.txt | 48508 | 43267 |
| asyoulik.txt | 44592 | 40024 |
| cp.html | 7656 | 7887 |
| fields.c | 3016 | 3333 |
| grammar.lsp | 1288 | 1563 |
| kennedy.xls | 51052 | 80854 |
| lcet10.txt | 119428 | 106821 |
| plrabn12.txt | 165580 | 145532 |
| ptt5 | 40000 | 50290 |
| sum | 9452 | 13184 |
| xargs.1 | 1808 | 2031 |

文章4fileはサイズで勝るが、全11fileの圧縮・復号中央値は7-Zipより長い。kennedyの+29802 B、ptt5の+10290 Bが大きい率の弱点で、勝てる文章だけを採用して完成としない。random64KiBはstored65576 B対XZ65596 Bだが、圧縮試行を経るため中央値299.751ms対97.415ms。これはearly stored判断を検討する根拠であり、ランダムに見えるだけで圧縮不能と断定してよい根拠ではない。

率優先の5%削減目標はこの集合で467761 B以下、現在から27025 B以上の削減が必要。同等以下の処理時間も必要で、サイズ改善だけでは合格しない。速度優先ではまず2406 B以上の削減と、7-Zipに対して圧縮/復号の両方10%以上速いことが必要。この診断集計へ適用すれば圧縮1216.780ms以下・復号977.390ms以下であり、現在KHCから10%改善するだけでは足りない。基準を変更せず、不足を明示する。

## 証拠・再現・予算

- a report：build/khc-cpu-measurement-v2-20261005-seven-empty-a/report.json、23153 B、SHA256 506D5A9B2A1BA024CBC86DE468DE56E6D693C0C303B45D599D5843CB1B533576。
- b report：build/khc-cpu-measurement-v2-20261005-seven-empty-b/report.json、26725 B、SHA256 2EDEC616F569EB7168A70755B6FE8A72B04F21C6F66ADD9C6B91724A0ABAF6BF。
- c report：build/khc-cpu-measurement-v2-20261005-seven-empty-c/report.json、24480 B、SHA256 963EC50E05F452E1BCEE6EFCBE0A66D8DFD283993CC6AB113CC7F181327CDC72。

run.ps1へ新empty EXE/SHA D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79E、既存7za EXE/SHA EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0を渡し、HistoryMode paid、BaselineKind lzma2、CorpusSet canterbury、AllowDifferentFrames、各FirstFixture/LastFixtureと未使用Attemptを指定する。

3report計74358 B。suite合計256795ms、CPUquiet待ち165967ms。各run900s/child60s/64MiB/CPUquiet15%ガード成功。生raw/frame disk保存0、追加build/download/dependency0、共有Cargo累計追加211794073 B/256MiBは増やしていない。事後空き27469398016 B、各dir8MiB以内。削除/Git/公開なし。今回はsource未変更なので既存E2E/clippy成功を再利用し、全repo/他OS nativeを再実行したとは報告しない。

opop観点はSEVEN_EMPTY_PLANで親が全担当。Performance/Testerの全体差・カウンタ確認を完了、Hardening/Asyncのguardsと子process終端確認を維持、Intelは公式版を再確認、Startupは起動込みと区別。他3観点は追加変更不要。このturnの新規委任なし。

## 次の判断と未達

GOAL active、率優先・速度優先とも未達。Canterburyは既知developmentであり、未見データやsolid/archive、既圧縮/暗号化、Zstd再評価の代わりではない。

復号側はDECODE_CANDIDATESのForest固定コピー（6979584 B/ブロック）、active prefix移動を検証候補とする。率側は表計算/bit画像/binaryを弱点として、可逆なbyte-plane/差分変換等を小さなprototypeで比較する。既存方式との先行例・ライセンスを確認し、変換識別子/復元metadataを全課金し、恒常的な多重圧縮試行で時間条件を悪化させない選択方式まで評価する。これは未実装・未実測の候補で、採用済みや新しい圧縮原理とは主張しない。固定した全developmentで判断し、率を変えないmicro改善だけを完了条件の代替として続けない。
