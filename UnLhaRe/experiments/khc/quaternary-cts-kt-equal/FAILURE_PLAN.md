# KT同値mass再利用の反証計画（2026-10-04）

先行診断はCTSの局所調査を優先する根拠まで。mass分布は未測定だが、小さな候補のfull-codec ABBAで実益を直接反証する。10倍改善は期待値として主張しない。
private depth版ktだけ変更し、製品・既存凍結ソース・証拠は維持する。

## 起こり得る失敗と対策

- 数値/拒否差: prefix→全4raw和/CAP→全active mass/total→zero total のguardを保持する。各childのchecked productも原順で必ず実行。既出massを見つけた場合だけ、Hamilton補正前のquotient/remainderをコピーする。checked sum、Hamilton left/order child昇順tie-break/increment、最終vector検査は全て旧原文維持。補正後quotientの再利用禁止。
- 全異値の純増/除算最適化: prefix最大4の比較探索が増え、div/remが一命令に統合される可能性もある。削減機会はk→distinct mass U、実際の分布と速度は未測定。full-codecで両方向短縮しなければ非採用。同条件の好結果狙い再試行なし。
- 誤配線: baseline codecの旧depth Cts、旧Math/旧poolを保持。候補codecのみ専用Ctsへalias、frozen modelを両方で共有sourceとして型ごとにinstantiate。拒否E2Eへ到達するため新codec両コピーのmodel moduleにpub(crate)だけ追加する（製品/public ABIは不変）。Cts/kernel/seal/observe bodyはkt loop以外変更しない。
- E2E差: 新unit testを書かず、計画済みstandalone比較でprefix1..4、全同値/2/3/4distinct、同値余りのtie、CAP近傍と超過、inactive rawによるCAP、prefix0/5、決定的raw群をold/new直接比較。各Ctsの既存拒否E2Eも実行。ABBA一周old/new/new/old各encode/decode1回、全plain4、全frame3、Proof全14field（CDF bits）とstats直接一致、frame478750Bと483599B上限を維持する。
- 誤った採用: old/new各2回平均、encode/decode双方短縮のみ次段候補条件。一周・warmupなしで正式採用はしない。median<574.5624ms、CPU<=15%、独立holdout/categories、4native/製品APIは未検証。
- 容量/失敗: 新source7file<=300KiB、build専用8MiB、EXE1MiB/report256KiB、空き5GiB+8MiB、disk-budget前後。compile60秒、contract90秒、ABBA90秒。stdout64KiB/stderr16KiB制限、kill所有child/終了待ち、失敗reportもbounded保存。Cargo/PDB/rawtrace/frame/plain/input copyなし。出力既存なら拒否、削除なし。
- identity変化: predict-split report SHA E1EF1915ECC9F3CE3A505B50D0FE3AF4986841B7ECFA20CB32E539FEDC9478ECの197identitiesを継承、新source/report/EXEをbefore/after/live照合。数値allowlistとgraph閉包を確認し、独立読取検証後に実行する。

親所有はverify.ps1/結果、worker所有はcodec.rs,optimized_codec.rs,probe.rs,integer_cts.rs,comparison.rs。既存編集/Git/外部/リリース/削除は禁止。
6基本観点はexp-zeroとpredict-split計画を継承。Performanceは同値division再利用、Tester/Hardeningは拒否・tie・全frame、Asyncはrunner寿命。Modernizer/Normalizer/Cleanerは現状維持、Startup/Intel非該当。読み取りanalystで数学的成立/強い反証を確認済み、親は分布診断を増やさずこの小候補を直接ABBA評価する判断。
