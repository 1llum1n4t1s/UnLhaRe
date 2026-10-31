# 更新版対7-Zip：development診断結果（未達）

2026-10-05 Windows x64。SEVEN_ZIP_PLAN_20261005の16入力を変更せず、640 native呼出し・320自己往復を完走、元byte完全一致、全source/input/tool pin前後一致。公式7-Zip26.03をhttps://www.7-zip.org/で再確認し、既存7za iでも26.03 x64を確認。比較はLZMA2/XZ mx9、mmt1、md4m、mfb273、KHC default paidの独立block。全argvはreport保存。

## Canterbury全11file

原文合計2810784 B。合計サイズは全header/model/checksum/終端込み。時間は各fileの9測定中央値を合計した診断集計で、単一solid/archive batch全体の中央値ではない。process起動・binary I/O込み。

| 指標 | 7-Zip | KHC |
| --- | --- | --- |
| 合計圧縮物 B | 492380 | 494786 |
| 圧縮中央値合計 ms | 1275.322 | 4051.640 |
| 復号中央値合計 ms | 1036.631 | 1590.572 |
| 最大kernel peak WS B | 31977472 | 27897856 |
| 最大観測private B | 57810944 | 25427968 |

KHCは総サイズ約0.49%大きく、圧縮約3.18倍・復号約1.53倍の時間。メモリは小さいが事前固定の率優先/速度優先ゲートを満たさない。GOALはactive、未達。未見セットを測る前に、既知developmentで弱点を改善する。勝てるfileだけを選んで完成にしない。

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

文章4fileはサイズ優位だが、表計算kennedy（+29802 B）、bit画像ptt5（+10290 B）、binary sumが大きい弱点。KHCは全実fileで圧縮・復号が遅い。境界syntheticではempty/1B/randomでheader費用が軽い一方、repeat4KiB 293対88 B、all256×8 804対308 Bで負ける。

## 証拠・再現・予算

report：build/khc-cpu-measurement-v2-20261005-seven-development/report.json、50438 B、SHA256 D297690F816D8A88FFC32F1E32332F4575BD0264BED615AA04938B26A37E99D1。

`run.ps1 -NewHelperExe <khc_leaf_probe.exe> -NewHelperSha256 A92088A87879B4328EA61179BCAD7BAB741D1BE2CB9DACE1598C523FBE2F234D -BaselineHelperExe <7za.exe> -BaselineHelperSha256 EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0 -Attempt <未使用名> -HistoryMode paid -AllowDifferentFrames -BaselineKind lzma2 -CorpusSet canterbury`。

Suite172909 ms、CPUquiet待ち73859 ms。両方式warmup1＋9、旧新順交互。別形式なのでcross-decodeは非該当。64MiB WS/private ceilingを全childで確認し、privateの短命最終peak取り逃しの可能性はreportに明記。入力最大1MiB以下を覆う4MiB辞書で、mx9/fb273を固定しているが、全setting/他方式の最適を証明していない。solid/archive、既圧縮/暗号化、未見、Zstd/現行再測定は後続評価。

raw/frame disk保存0、新buildなし、report50KiB未満。出力8MiB/free5GiBガード成功、空き約29.5GB。共有Cargoの累計追加204953438 B/256MiBは変化なし。削除/Git/新依存/外部書込みなし。

次の具体的改善：encoderはrootごとに同じdefault uniformをserialize/parseし1024 CDF比較を行う。root_defaultはsplit=falseかつ同じuniform CDFを保証し、packetはobjective=0との一致を検査してdefault flagだけを保存する。default rootの検証をk別にblock内1回へ集約する候補を、全frame一致と回帰E2Eで検証する。decoderの検査は削らない。率側の弱点は上記binary/bit画像に残り、速度改善を率改善の代わりにしない。
