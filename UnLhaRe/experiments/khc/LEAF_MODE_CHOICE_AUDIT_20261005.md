# 固定葉候補の独立調査と採否

前段実測paid-code-treeは484286 B、gate483599 Bに687 B不足。旧木同tableに比べ20 Bだけ改善。独立analystは最大6資料で「compact既存＋uniform＋pure全dominant」の1候補を返却した。現model.rs:28-35は単一compact_frequency(quantize(counts))だけをsplitと比較するため、既存wireの短modeをcount損失込みで選べない場合がある。teacher・frame・速度は別の未解決。

候補をprivate診断として採択する。固定table・wire・depth・履歴・支持min2を変更せず、候補集合を増やすだけなので、旧DP候補が残り共同bit目的を悪化させない。最大6固定候補/各node、未知minor19 bit・table134 Bを維持。687 B改善の根拠はまだなく、診断結果で棄却する。

反証：現在ESC0なので未知回避だけでは不足。同木原Hamiltonとの差244.158 bitは約30.5 Bのみ。compact1055葉に対する不足5496 bitは約5.21 bit/葉。大きい非uniform countが多ければ新uniform/pureの損失は保存費削減より大きく、no-goになる。

| 観点 | 担当／結果 |
| --- | --- |
| Performance | 独立analyst＋親。単一CDF候補の取りこぼしを固定最大6候補へ拡張、効果は実screenで判定。node/decoder仕事量を増やさず、学習loss計算の追加は計上する。 |
| Hardening | 独立analyst＋親。pure全child min2、uniformは旧quantize([0;4])、CDF/fee/親子Histを保つ。旧leaf frequency==新leaf assertは撤回し、旧decodedCDFを旧compact(quantize(counts))に直接照合。 |
| Tester | 独立analyst＋親。失敗条件を先行保存、全k/非pure count/全dominant/旧保持tie/default/compact/低高/深いsplit/回復、全実CDFと本入力共同目的を照合。 |
| Normalizer | 親。表・parser・grammar/Hist数値を凍結参照し、通常経路を一本化。原Hamiltonとの差は新CDF選択差として表示しfloor誤差に偽装しない。 |
| Cleaner | 親。旧証拠を再現資産として保持、新duplicate bundle/codebookは作らない。rawコピー・清掃・共有cache操作0。 |
| Modernizer | 親。依存/version/runtime変更は不要、今回非該当。 |
| Async | 親。候補はstackで逐次評価、codec/report同時保持を避け、全capacity式を再確認。非同期化なし。 |
| Intel/Startup | 親。外部現在仕様・製品配布を変更しないため非該当。 |

共同目的改善はbyte切上げ込み最適の保証ではない。teacher状態・静かなCPU条件・全CLI速度・holdout・4nativeは未証明のまま。採用判定は親が保存結果を再検証して行う。Git・外部・削除・製品・x86変更0。
