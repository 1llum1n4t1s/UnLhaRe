# Uniform dispatch一括代入：互換性確認、速度優位は未実証

2026-10-05 Windows x64。FILL_PLANの候補を公開API経由で検証した。parse_packet_nodeのdefault分岐でuniform(k)を1024回呼ぶ代わりに1回計算し、同じgroupの1024slotへ標準slice.fillで複製する。k=2..4、g=k-2、GROUPS*HISTORIESの確保範囲、flag消費順、nondefault検査、defaultカウンタは維持する。追加allocation、形式、revision、整数CDFの変更はない。

採用理由は同じ値の反復計算をソース上1024→1回へ減らし、標準の一括設定へ集約できること。最適化後の機械語で同じ削減が成立するかは未計測で、実測時間の改善とは区別する。高速化の成果や7-Zip優位としては数えない。

## 実経路の検証

同じ7fixture、warmup1＋9、順序交互、Paid/Low各294 native呼出し、計588。各mode70組すべて圧縮物の全byte一致、140自己往復と14両方向相互復号成功。source/input/toolのpinは前後不変。Paid reportの29pinは本ターンの現行ソースと再照合して一致した。

時間はprocess起動＋binary I/O込みで、純codec CPUではない。代表的な旧→新の中央値ms：

| 入力 | Paid圧縮 | Paid復号 | Low圧縮 | Low復号 |
| --- | --- | --- | --- | --- |
| repeat4KiB | 126.641→107.687 | 89.392→86.438 | 105.392→108.548 | 96.972→96.412 |
| all256×8 | 110.423→106.256 | 107.604→108.290 | 108.881→105.496 | 121.710→96.065 |
| alice29 | 300.823→282.559 | 138.334→141.909 | 260.264→250.505 | 139.768→141.939 |
| kennedy | 764.264→767.393 | 314.213→320.017 | 662.735→660.877 | 320.031→303.074 |

全fixtureの旧新min/max範囲は重なる。改善・悪化いずれも確定的とは主張しない。Lowは375059ms中323852msがCPUquiet待ちで、別作業も稼働していた。quiet上限15%、child64MiB/60s、suite900sを緩めず完走したが、測定環境の変動を隠さない。Low最大WS27611136 B、private24842240 B、Paidも64MiB上限内。サイズはすべて不変。

回帰：固定all.groupを指定した既存khc_block_normal、khc_block_adversarial、khc_model_boundaryが成功。3blockは156483/237176/119861 B、完全復元。30故障/30回復、oversize拒否、852最大分割rootの復号を確認。lib＋fill exampleのclippy -D warnings、変更2Rustファイルのrustfmt check成功。全repo/container/他OS nativeは今回再実行していない。

E2E成果物はbuild/khc-product-e2e-20261005/block-normal-40560/result.json、block-adverse-34616/result.json、model-boundary-30940/result.json。最大分割の復号52.089msは単発の回帰検証値で、比較速度の証拠ではない。

## 保存・再現・容量

旧default probe SHA256 675F919E7C57EE074211CB7D6894248E2082C98D99F70AB5E007938DD2F978FD、新fill probe 3F9E8ABA9500D0DF085A49DB071DBAF09DE3FE8FE4BB25C2C9263EB13FD2F63F。paid_model.rs SHA256 E276A2D8813864A83F0038529054A98FE085E2607997E39AB918780A66890A9F。

再現はrun.ps1へ上記NewHelperExe/SHA、BaselineHelperExe/SHAを渡し、HistoryMode paidまたはlow、Attemptは未使用名とする。AllowDifferentFramesは付けない。

- Paid：build/khc-cpu-measurement-v2-20261005-fill-paid/report.json、25104 B、SHA256 510A4E92378B6149C4F9270981D39BB252CFA0840BBC21EA0F9CBA25B05837EF。
- Low：build/khc-cpu-measurement-v2-20261005-fill-low/report.json、25150 B、SHA256 C03392DBA6A68C6EF90F53A6BDA6CFFCF8EDDE3A7CFDFE89492113A2812F7D68。
- report計50254 B、raw/frame disk保存0。E2E累計6333294 B/8MiB。
- 共有Cargo6116301780 B、元baselineから209508700 B追加/256MiB、残り58926756 B。事後空き28769722368 B。今回のsource/result等は小さな再現成果物として保持し、削除・Git・外部公開・追加依存なし。

opop全観点は親担当。Performanceはソースの反復回数削減を採用、実測速度優位は証拠不足。Normalizer/Cleanerは同原因の標準一括設定へ統合。Hardening/Testerはbyte互換と既存異常系で確認。Modernizerは追加変更不要、Asyncは寿命不変、Startup/Intelはこの変更では非該当。

## GOALと次の判断

GOALはactive、7-Zipへの総合優位は未達。旧leaf版の全Canterbury対7-Zip結果をこの変更の測定として読み替えない。GOAL_GATEの基準は維持する。

次の候補はFit::build_nodeの空の頻度枝の量子化/モデル選択削減。現状は空の枝にも深さ5まで再帰し、quantize/compact/leaf/split比較を行う。子の非負countと全parent=sum(children)を検査した上で、空枝はuniform非分割で終了できる可能性がある。整合性チェックの抜け、tail/CAP、未訪問Nodeへのlookup、同点選択を反証する失敗先行計画と、旧fill EXEを保持した全frame互換測定を先に用意する。未実装・未実測であり、効果をまだ主張しない。
