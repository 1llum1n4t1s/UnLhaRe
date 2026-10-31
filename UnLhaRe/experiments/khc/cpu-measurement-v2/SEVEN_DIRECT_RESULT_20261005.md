# 直接parse版対7-Zip：全developmentの未達を確認

2026-10-05 Windows x64、SEVEN_DIRECT_PLANの16fixture全体を3区間で完了した。640native calls/320自己往復、元byte完全一致、全pin前後一致、cross0。入力index0..15を重複/欠落なしで照合。現行direct EXEを実際に測定しており、旧empty/leafの時間を転用しない。

7-Zip実行ファイルのversion26.03（2026-09-03）/SHA EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0を再確認。公式現行確認は同日SEVEN_EMPTY_RESULTを参照。LZMA2/XZ mx9/mmt1/md4m/mfb273、dict4MiBは全入力最大1MiBを覆う。両方式64MiB child上限。全設定空間での7-Zip最適を証明した比較ではない。

## 全Canterbury11file

原文2810784 B。全header/model/checksum/終端込み。時間は9測定の各file中央値を合計、process起動＋I/O込みで純codec/batch/solid中央値ではない。最大privateは短命最終peakを取り逃す可能性がある。

| 指標 | 7-Zip | 現在KHC direct |
| --- | --- | --- |
| 総圧縮物 B | 492380 | 494786 |
| 圧縮中央値合計 ms | 1370.031 | 2771.921 |
| 展開中央値合計 ms | 1100.619 | 1322.446 |
| 最大kernel peak WS B | 31973376 | 27897856 |
| 最大観測private B | 57798656 | 25432064 |

KHC総サイズ+0.49%、圧縮約2.02倍、展開約1.20倍。率は旧emptyと同じ、decoder改善の旧新paired根拠はDIRECT_PARSE_RESULTで分離する。旧emptyの約2.25/1.44倍との違いは別時刻/別runのhistorical比較であり、直接parseだけの因果的効果や独立反復の証明とはしない。

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

fields/grammarの展開中央値はKHCが短いが、範囲は重なり率も劣るため勝利扱いにしない。文章4fileの率優位も全体優位ではない。kennedy +29802 B、ptt5 +10290 Bが率の大きい弱点。単純filter4候補は全fileで悪化し別報告で打切済み。同じfilterを繰り返さない。

GOAL_GATE率優先の全体467761 B以下（さらに27025 B削減）かつ同等以下の時間/RAMは未達。速度優先は7-Zip以下のサイズ（さらに2406 B削減）、今回診断合計なら圧縮1233.027ms以下/展開990.557ms以下が必要。KHC内10%改善だけでは合格しない。未見評価・別順序独立反復も未完了。メモリ優位だけで完成しない。

## 証拠・再現・容量

- a：build/khc-cpu-measurement-v2-20261005-seven-direct-a/report.json、23008 B、SHA256 9FA034517619D50A977D71AC474598B31EDB4C4A3E56CD570DDD7F9077054CBF、200calls/0..4。
- b：build/khc-cpu-measurement-v2-20261005-seven-direct-b/report.json、26648 B、SHA256 DA392AFC356D7B7A910CD3DE8AF27215A3ACAB353E0FAC42F5290663D0171894、240calls/5..10。
- c：build/khc-cpu-measurement-v2-20261005-seven-direct-c/report.json、24439 B、SHA256 A967E80A256ECF8D2BAB02B026030B2D36140005F1D3B28537E976C7A79AD7E9、200calls/11..15。

合計74095 B。runnerへ新direct EXE/SHA 87D22FCD6E500BCBB26371BC4B86C19208796C36D6D596F7E89D18CFEB9C115C、7za EXE/SHA、HistoryMode paid/CorpusSet canterbury/BaselineKind lzma2/AllowDifferentFrames、各区間/unused Attemptを明示する。全source/plan/runner/tool/input/config pinと生9sampleはJSONへ保存。

最初の外側PowerShellループはa完了後、直接.ps1呼出しがLASTEXITCODEを設定しないためnullを非zeroと扱い終了した。aのterminal成功とb/c未作成を確認し、aを再実行せず、残るb/cはbundled pwsh -NoProfile -Fileによる明示exit code取得へ修正して完了した。別のread-only確認は誤ってrepo root相対pathを使いfile-not-foundになったが、Rust project cwdでcorrect path/SHA/状態を確認し直した。これはnative測定の失敗/再試行を隠したものではない。

追加build/downloadなし、raw/frame disk0。前後disk-budget全3dir8MiB内、最終free27441401856 B。共有Cargo6123283030 B、baselineから累積216489950 B/256MiB、残51945506 Bを維持。製品source変更・2probe比較・この再評価を合わせて新測定JSON124599 B、E2E追加JSON約8KiB、probe約0.97MiBと小さい文書/sourceを保持。削除/新target-dir/依存/Git/公開なし。全native測定sessionはterminal exit0で完了し、同codec/7zaプロセス残存は確認範囲でなし。

GOAL active、完成未達。次は率の弱いbinaryへ適した別predictor/符号化を小試作し、圧縮試行費用も課金して比較する。既存BWT経路のhot lookup費用も調査候補だが、互換micro改善だけを最終目的へ置換しない。固定基準を変更せず、採用候補のみ本体へ統合する。
