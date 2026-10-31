# Compact posterior full候補の結果

正確性とサイズは合格、速度は未評価。製品コードへの採用・総合7-Zip超えの証明ではない。

- 証拠: `../../build/khc-causal-compact-simd-20261002/report.json`、SHA256 `A98CA8C5B4ABA79F03D91171909755887DEC528AE50325F191EEA3BF63DC43CD`。
- 実行: UTC 2026-10-01T18:55:18.5008483Z〜18:56:02.012572Z、48 checks / 86 compiler・codec CLI / 269 identities。statusは `correctness_and_size_passed_not_timed`。
- normal/scalarと各overflow-check条件、7入力でframe・stdout・復元を比較。旧decoderとの双方向互換、破損入力・no-clobber・欠落入力の拒否も検証した。
- 固定入力のcomplete frameは483496B、SHA256 `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`。483599Bの上限内。符号化仕様・スケジュールは変更していない。

## 実装と使用確認

`causal-compact-simd/` は凍結済みBayes/整数候補から派生した独立した研究候補。heavy posteriorの4件グループを `Option<[u64;4]>` にして、一括計算できない場合は従来のlaneごとの計算へ戻す。計算順序・丸め・count/weight/history更新順を維持する。

別の診断EXEでは、encode/decodeそれぞれheavy event 3223156件に対して実kernel使用12892624グループ、fallback 0グループを確認。診断出力は同一で、正式計測用EXEにはカウンターを含めない。実際の型サイズはplain array 32B、compact Option 40B、従来Result array 96B。ただし、この値は処理全体のメモリ削減率や速度改善率ではない。

数値kernelの独立検証は `../../build/khc-compact-simd-20261002-coverage-repair/report.json`、SHA256 `C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935`。full候補の診断でfallbackがなかったことを、全入力やkernel内部の補正回数へ一般化しない。

## 容量と残作業

report保存後のfull出力は23746229B。その後の正式比較attemptは963Bで、親合計23747192B。PDB・一時ファイル・reparse pointなし。固定fixtureとコンパイラを再利用し、Cargo target/cacheや大量の生トレースを新設していない。report内のbudget_afterはreport自身の保存前の23548734Bであり、最終容量とは区別する。

正式速度比較は別の失敗記録を参照。holdout・カテゴリ別、同じ復号境界、四native環境での決定性、製品/API組込み・安全性は未完了。製品変更・commit・公開はしていない。
