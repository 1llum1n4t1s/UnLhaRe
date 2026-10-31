# CTS同一component診断: 実装追加を見送る

件数だけの診断は7確認/5CLI/478 unique identitiesで成功。基点full466レコードを前後照合し、counter encode/decodeの第1stdout・圧縮frame・復元を既存結果/元入力と実byte比較して一致した。商計算・浮動kernel・学習状態を変えていない。cfg-off/onはbuildし、onの固定input encode/decodeだけを実行した。

| groupのupper level | 全groups | 4lane全て同一componentかつceiling一致 | 少なくとも1lane一致 |
| --- | ---: | ---: | ---: |
| 3 | 3223156 | 259020 | 279655 |
| 7 | 3223156 | 288146 | 321208 |
| 11 | 3223156 | 339972 | 448815 |
| 15 | 3223156 | 511568 | 950101 |
| 合計 | 12892624 | 1398706 | 1999779 |

合計51570496 lane中6621637が等値（約12.840%）。4lane全部が等値なのはgroupの約10.849%。pk==childなのにcached_ceiling!=pkとなるケースは0。upperごと16maskの全histogramがencode/decodeで一致し、mask popcountから件数を独立に再集計した。

数学的には合法なpk==child>0、ceiling==pkのときposteriorはweightになり、整数商を省ける。しかし本corpusでは約89.151%のgroupで4本まとめて除算を除けない。groupごとの分岐/検査・部分laneを残す実装コストが増える可能性もあり、このcounterだけで時間や速度改善率は決められない。全CLIの大幅短縮を目指す現段階では、**all-equal group shortcutを実装しない**。将来別用途で測定する余地は残すが、今回の数値を正式性能/採用証拠として使用しない。

次の研究方向は、既存next-use rank/run-length grammarの1 bitごとに予測・学習する構造そのものを減らすこと。固定inputでは889227 runに対して7622618 binary eventsが生じ、イベントをmulti-symbol tokenへまとめれば、モデル更新とrange正規化の回数を減らせる可能性がある。これは未実装の仮説であり、圧縮率・復号・完全container・固定ゲートを別候補として実測する必要がある。現在のgrammarは一般的なMTFではなく、next-use順のactive listであることを確認した。既存rANS実験はbit-journal表現の変更で、このtokenモデル変更の証明ではない。

## 識別値・容量

- 契約 SHA256: `4226FE6A55B0B513C021F1978D2A0E6FCF87CFA5892CE5E6C2C0326B9E50CBBB`
- verifier `equal-component-opportunity/verify.ps1`: `28A8EA0859654F041BD09B328DFC5F868571FD917FC9BEA683E6EA12DE2EE8EC`
- `../../build/khc-equal-component-opportunity-20261002/report.json`: `BCD6B755595C96E22481BE540F58016F81DC755AAE48202592A0762F809C36E0`、193242B
- UTC実行: 2026-10-01T21:54:23.5067065Z～21:54:37.6805899Z。source完全対応・argv・runtime/compiler・CPU・全identitiesとhistはreport内。
- frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12は不変。

追加生成物は4files/1163650B（約1.110MiB）。2811006Bのrestoreは逐次実byte/長さ/hash照合の後、exact owned path・non-reparse・child終了とexclusive readを確認してRemove-Item -LiteralPathで削除した。reportにtransient_path・比較結果・削除済みフラグを残し、persistent identityへ登録していない。input/frame/EXE/reportは保持し、元入力とEXEから復元を再生成できる。PDB/cache/raw traceは作らなかった。

正式性能や同候補terminalを再試行せず、observer初期化分離も行っていない。固定CPU15%・サイズ483599B・encode median574.5624ms未満・warmup1+9を維持し、7-Zip総合超え/holdout/同境界decode/四native/製品APIは未達。goalはactive。
