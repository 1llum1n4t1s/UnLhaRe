# Q32商補正の対数表追加 — 正常比較条件

新LUT候補のfull-E2Eと独立監査が成功して凍結された後、専用root `build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/performance/` へ1sessionのみ試行する。

候補は同root親のcandidate.exe。対照は商補正のみ `build/khc-bwt-causal-bayes-q32-corrected-20261001/candidate.exe` SHA FC44562A23B61A6FD38FCE305B285185F82CB7D9CB0109E2E320CFDEEBF8027F。両者は同CTS/SA-IS/精度/grammar/全frameで、変数はBayes対数表とその構築・参照・保存形式のみ。元Q32/商補正の通常時間は未測定であり、商補正の性能採用を前提にしない。

親は凍結商補正compareを新scriptへ再利用し、候補/control/source/proofの固定SHAとラベルを変更する。新LUTbuild/full proofと旧LUT numeric proof/cleanup receipt/保持raw、既存Q32/BWT/商補正の各proofをreadlock下で照合。清掃済みLUT round1出力12件はreceiptの完全path/bytes/SHA一致と同byteの保持round0でのみ説明し、欠落を無条件で無視しない。

計測helper・quiet-host SHA E66D39AE...・事前5観測/各child前後<=15%、warmup1+9・循環3codec・120秒所有child・全CLIwall・memory/threadpollを不変とする。表容量262144Bと各stream初期化を含む。native7za26.03 SHA EDBEE353...、LZMA2:d=64m/mx9/mmt1/solid/時刻metadataなしを維持。

固定group2811006B/SHA18B8...、候補/control全frame483469B/SHA7584...を要求。archive<=483599B、strict encode<574.5624msを緩めない。同intervalのbusy拒否は失敗で、同候補のblind retry/CPU設定/他process停止なし。成果は局所候補の判断であり、総合7-Zip超過・4環境・holdout・製品統合の証拠としない。Git/version/公開なし。
